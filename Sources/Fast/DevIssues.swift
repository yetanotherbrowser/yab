import AppKit
import SwiftUI

// The card's list of what went wrong on the page, drawn as Chromium's console
// draws it: an error a pink row, a warning a yellow one, in a fixed-width
// face, the same words said again one row with a count, ▶ for the stack,
// where it was said on the right, a link into Sources. The failed requests
// are in it too, since what an agent needs is often "this error and that
// 500". Above it the filters, a search, and Copy for Agent, which hands the
// agent what the list shows as one piece of Markdown (DevCopy.pack); rows
// picked with a click, ⇧-click and ⌘-click, or ⌘A, go by ⌘C or the bar that
// comes up under them.

enum IssueFilter: Hashable {
    case all, errors, warnings, requests
}

/// One thing that went wrong: words the page said, or a request that failed.
enum Issue: Identifiable, Equatable {
    case said(DevLog.Entry)
    case request(DevLog.Request)

    var id: String {
        switch self {
        case .said(let entry): return "e:" + entry.id
        case .request(let request): return "r:\(request.id)"
        }
    }
}

extension DevLog {
    /// What the list shows under `filter`, the words searched for kept.
    func issues(_ filter: IssueFilter, matching words: String = "") -> [Issue] {
        var out: [Issue] = []
        if filter != .requests {
            out += entries.filter { filter == .all || $0.level == (filter == .errors ? .error : .warning) }.map(Issue.said)
        }
        if filter == .all || filter == .requests {
            out += requests.filter(\.failed).reversed().map(Issue.request)
        }
        let words = words.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return out }
        return out.filter { issue in
            switch issue {
            case .said(let entry): return entry.text.localizedCaseInsensitiveContains(words) || entry.source.localizedCaseInsensitiveContains(words)
            case .request(let request): return request.url.localizedCaseInsensitiveContains(words) || String(request.status) == words
            }
        }
    }

    /// Where a row was said, as a place in a file: its first frame of the
    /// page's own, else where the browser said it was.
    nonisolated static func place(_ entry: Entry) -> DevPlace? {
        let (own, all) = frames(entry.stack)
        for line in [own.first, all.first, entry.source.isEmpty ? nil : entry.source].compactMap({ $0 }) {
            if let place = DevPlace(line) { return place }
        }
        return nil
    }
}

/// A file and a line in it, read off a line of a stack.
struct DevPlace: Equatable {
    let url: String
    let line: Int
    let column: Int

    /// `name@https://…/app.js:14:22`, `at https://…:14`, `app.js:14:22`.
    init?(_ said: String) {
        var place = said.trimmingCharacters(in: .whitespaces)
        if let at = place.firstIndex(of: "@") { place = String(place[place.index(after: at)...]) }
        if place.hasPrefix("at ") { place = String(place.dropFirst(3)) }
        let parts = place.split(separator: ":", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        var rest = parts[...]
        while let last = rest.last, let number = Int(last), numbers.count < 2 {
            numbers.insert(number, at: 0)
            rest = rest.dropLast()
        }
        guard let line = numbers.first, !rest.isEmpty else { return nil }
        url = rest.joined(separator: ":")
        self.line = line
        column = numbers.count > 1 ? numbers[1] : 1
    }

    /// As the row's right end says it: the file and the line.
    var short: String {
        let name = URL(string: url).map { $0.lastPathComponent.isEmpty || $0.lastPathComponent == "/" ? ($0.host() ?? url) : $0.lastPathComponent } ?? url
        return "\(name):\(line)"
    }
}

// MARK: - what the agent gets

extension DevCopy {
    struct PackOptions {
        /// The page's address and size, and the browser.
        var page = true
        /// What a failed request sent and got back.
        var bodies = true

        @MainActor static var kept: PackOptions {
            PackOptions(page: Store.settings.object(forKey: "dev.pack.page") as? Bool ?? true,
                        bodies: Store.settings.object(forKey: "dev.pack.bodies") as? Bool ?? true)
        }
    }

    /// Errors, warnings and failed requests, and the console's lines when
    /// asked for, as one piece an agent reads: what, where, how often, what
    /// the server said, its secrets out.
    @MainActor static func pack(_ issues: [Issue], console: [String] = [], page: URL?, size: CGSize?, options: PackOptions? = nil) -> String {
        let options = options ?? .kept
        let said = issues.compactMap { if case .said(let entry) = $0 { return entry } else { return nil } }
        let errors = said.filter { $0.level == .error }, warnings = said.filter { $0.level == .warning }
        let failed = issues.compactMap { if case .request(let request) = $0 { return request } else { return nil } }
        var counts: [String] = []
        if !errors.isEmpty { counts.append(errors.count == 1 ? "1 error" : "\(errors.count) errors") }
        if !warnings.isEmpty { counts.append(warnings.count == 1 ? "1 warning" : "\(warnings.count) warnings") }
        if !failed.isEmpty { counts.append(failed.count == 1 ? "1 failed request" : "\(failed.count) failed requests") }
        if !console.isEmpty { counts.append(console.count == 1 ? "1 console line" : "\(console.count) console lines") }
        var out = "## \(where_(page)): \(counts.isEmpty ? "nothing went wrong" : counts.joined(separator: ", "))\n"
        if options.page {
            var line: [String] = []
            if let page { line.append("Page " + clean(page.absoluteString)) }
            if let size, size.width > 0 { line.append("\(Int(size.width))×\(Int(size.height))") }
            line.append(browser)
            line.append(Date().englishFormatted(date: .abbreviated, time: .shortened))
            out += line.joined(separator: " · ") + "\n"
        }
        for entry in errors + warnings {
            out += "\n### \(entry.level == .error ? "Error" : "Warning"): \(clean(entry.text))\(entry.count > 1 ? " ×\(entry.count.formatted())" : "")\n"
            let (own, all) = DevLog.frames(entry.stack)
            if !all.isEmpty {
                let shown = Array((own.isEmpty ? all : own).prefix(8))
                for frame in shown { out += "  at \(DevLog.frame(frame, page: page))\n" }
                let more = all.count - shown.count
                if more > 0 { out += "  … \(more) more \(more == 1 ? "frame" : "frames")\n" }
            } else if !entry.source.isEmpty {
                out += "  at \(DevLog.frame(entry.source, page: page))\n"
            }
        }
        if !failed.isEmpty {
            out += "\n### Failed requests\n"
            for request in failed {
                let path = URL(string: request.url).map { $0.path() + ($0.query().map { "?" + $0 } ?? "") } ?? request.url
                out += "- \(request.method) \(clean(path)) → \(request.status == 0 ? "failed" : String(request.status)), \(request.ms) ms\n"
                if let failure = request.failure { out += "  \(clean(failure))\n" }
                if options.bodies {
                    if let body = request.requestBody, !body.isEmpty { out += "  sent: \(clean(short(body)))\n" }
                    if let body = request.responseBody, !body.isEmpty { out += "  → \(clean(short(body)))\n" }
                }
            }
        }
        if !console.isEmpty {
            out += "\n### Console\n"
            for line in console.suffix(300) { out += clean(line) + "\n" }
            if console.count > 300 { out += "… \((console.count - 300).formatted()) earlier lines left out\n" }
        }
        out += "\nKeys, tokens and cookies are taken out.\n"
        return out
    }

    /// Yab and the Safari whose WebKit it runs on.
    private static var browser: String {
        let yab = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let safari = Web.userAgentName.split(separator: " ").first.map { $0.replacingOccurrences(of: "Version/", with: "") }
        return "Yab" + (yab.map { " " + $0 } ?? "") + (safari.map { ", WebKit (Safari \($0))" } ?? "")
    }

    /// A body on one line, an HTML page's as its words, not its markup.
    static func short(_ text: String) -> String {
        var one = text
        if one.trimmingCharacters(in: .whitespaces).hasPrefix("<") {
            one = one.replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
            one = one.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            one = one.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        }
        one = one.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return one.count > 600 ? String(one.prefix(600)) + " …" : one
    }
}

extension Browser {
    /// The list's issues handed to the agent, and said so.
    func copyIssues(_ issues: [Issue], console: [String] = [], on tab: Tab) {
        copyForAgent(DevCopy.pack(issues, console: console, page: tab.address, size: tab.builtPage?.bounds.size), "Copied for your agent")
    }

    /// Everything: the list's issues and every line of WebKit's console,
    /// which its inspector keeps from the page's start.
    func copyEverything(_ tab: Tab) {
        let issues = tab.devLog.issues(.all)
        withInspector { [weak self, weak tab] inspector in
            DevTools.consoleLines(in: inspector) { lines in
                guard let self, let tab else { return }
                self.copyIssues(issues, console: lines, on: tab)
            }
        }
    }

    /// Where a row was said, in WebKit's Sources at the line; in its
    /// console when Sources doesn't have the file.
    func revealSource(_ place: DevPlace) {
        pickDevPane(.sources)
        sourcesRefresh()
        workCall("sources.files") { [weak self] value in
            guard let self else { return }
            let rows = value as? [[String: Any]] ?? []
            if let row = rows.first(where: { $0["url"] as? String == place.url }) {
                self.sourceOpen(DevSource(script: row["id"] as? String ?? "", url: place.url, target: row["target"] as? String ?? "", frame: row["frame"] as? String ?? "", kind: row["type"] as? String ?? "script"), line: max(0, place.line - 1))
            } else { self.workbench?.error = "The source is no longer available: " + place.url }
        }
    }
}

// MARK: - the list

struct DevIssues: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var log: DevLog
    let filter: IssueFilter
    let wide: Bool
    @State private var words = ""
    @State private var picking = IssuePicking()
    @State private var open: Set<String> = []
    @State private var pack = DevCopy.PackOptions.kept
    @FocusState private var focused: Bool

    var body: some View {
        let shown = log.issues(filter, matching: words)
        VStack(spacing: 0) {
            toolbar(shown)
            Rectangle().fill(Palette.ink.opacity(0.06)).frame(height: 1)
            if shown.isEmpty {
                DevQuiet(words: quiet)
            } else {
                ThreadScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { issue in
                            IssueRow(issue: issue, page: tab.address, selected: picking.picked.contains(issue.id), open: open.contains(issue.id),
                                     checking: !picking.picked.isEmpty, wide: wide,
                                     pick: { pick(issue, in: shown) },
                                     check: { focused = true; picking.toggle(issue.id) },
                                     toggle: { toggle(issue) },
                                     copy: { browser.copyIssues([issue], on: tab) },
                                     reveal: { browser.revealSource($0) },
                                     inspect: { browser.showInInspector(console: true) },
                                     network: { if case .request(let request) = issue { browser.netShow(request) } },
                                     curl: { if case .request(let request) = issue { browser.copyForAgent(DevCopy.curl(request), "Copied as cURL") } })
                                .equatable()
                        }
                        // Room for the bar over the last rows.
                        if !picking.picked.isEmpty { Color.clear.frame(height: 48) }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !picking.picked.isEmpty {
                selectionBar(shown)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(Motion.quick, value: picking.picked.isEmpty)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onCommand(#selector(NSText.copy(_:))) { copy(shown) }
        .onCommand(#selector(NSText.selectAll(_:))) { picking.all(shown.map(\.id)) }
        .onExitCommand { picking.none() }
        .onChange(of: log.since) { picking.none(); open = [] }
        .onChange(of: filter) { picking.none() }
        // What the search hides is no longer picked: it would be copied
        // unseen, and come back picked when the search is cleared.
        .onChange(of: words) { picking.keep(log.issues(filter, matching: words).map(\.id)) }
    }

    private var quiet: String {
        if !words.isEmpty { return "Nothing matches “\(words)”" }
        switch filter {
        case .errors: return "No errors since the page loaded"
        case .warnings: return "No warnings since the page loaded"
        case .requests: return "No failed requests since the page loaded"
        case .all: return "Nothing went wrong since the page loaded"
        }
    }

    // MARK: the bar over the list

    /// The search, the filters and Copy for Agent; beside the page, where
    /// the card has 460 to 500 points, on two rows (IssueBar).
    private func toolbar(_ shown: [Issue]) -> some View {
        let failed = log.requests.lazy.filter(\.failed).count
        let errors = log.entries.lazy.filter { $0.level == .error }.count
        let warnings = log.entries.count - errors
        return IssueBar {
            HStack(spacing: 4) {
                Symbol("magnifyingglass", size: 10).foregroundStyle(Palette.muted)
                TextField("Filter", text: $words)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 0, idealWidth: wide ? 200 : 120, maxWidth: .infinity)
            // As high and as round as Copy for Agent at the row's end.
            .frame(height: ButtonSize.small.height)
            .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .layoutValue(key: IssueBar.Role.self, value: .search)
            chip(.all, "All", errors + warnings + failed, nil)
            chip(.errors, "Errors", errors, "xmark.circle.fill")
            chip(.warnings, "Warnings", warnings, "exclamationmark.triangle.fill")
            if wide || failed > 0 { chip(.requests, wide ? "Failed Requests" : "Failed", failed, nil) }
            if wide {
                Button("Ask in Chat") { browser.askInChat(about: tab, selection: DevCopy.pack(shown, page: tab.address, size: tab.builtPage?.bounds.size)) }
                    .buttonStyle(.yab(.quiet, .small))
                    .disabled(shown.isEmpty)
            }
            CopySplit(copy: { copy(shown) }, menu: { copyMenu(shown) })
                .disabled(shown.isEmpty)
                .keyTip(picking.picked.isEmpty ? "Copy what the list shows, for your agent" : "Copy the rows picked, for your agent")
        }
        .font(.system(size: 11.5, weight: .medium))
        .focusable(false)
        .padding(.horizontal, DevLook.padding)
        .padding(.vertical, 3) // design: 24-point controls in a 30-point row, as Network's toolbar
    }

    private func chip(_ which: IssueFilter, _ title: String, _ count: Int, _ mark: String?) -> some View {
        Button { pickFilter(which) } label: {
            HStack(spacing: 4) {
                if let mark { Symbol(mark, size: 9).foregroundStyle(which == .errors ? DevLook.errorMark : DevLook.amber) }
                Text(title)
                Text(count.formatted()).monospacedDigit().foregroundStyle(filter == which ? Palette.ink : Palette.muted)
            }
            .fixedSize()
        }
        .buttonStyle(.yab(filter == which ? .secondary : .quiet, .small))
        .layoutValue(key: IssueBar.Role.self, value: .filter)
    }

    private func pickFilter(_ which: IssueFilter) {
        browser.issueFilter = which
        switch which {
        case .warnings: browser.devPane = .warnings
        default: browser.devPane = .errors
        }
    }

    /// The chevron's menu, as the small window's spaces: first what the
    /// button does, with ⌘C; then the rest to copy instead, each copied at
    /// once; then what goes with it, ticked.
    private func copyMenu(_ shown: [Issue]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let picked = shown.filter { picking.picked.contains($0.id) }
        let first = PageMenuItem(picked.isEmpty ? "What the List Shows" : picked.count == 1 ? "The Row Picked" : "The \(picked.count) Rows Picked") { copy(shown) }
        first.keyEquivalent = "c"
        first.keyEquivalentModifierMask = [.command]
        menu.addItem(first)
        menu.addItem(.separator())
        menu.addItem(PageMenuItem("Errors, Warnings and Failed Requests") { browser.copyIssues(log.issues(.all), on: tab) })
        menu.addItem(PageMenuItem("Errors Only") { browser.copyIssues(log.issues(.errors), on: tab) })
        menu.addItem(PageMenuItem("Everything in the Console") { browser.copyEverything(tab) })
        menu.addItem(.separator())
        let page = PageMenuItem("With the Page’s Address and Size") {
            pack.page.toggle()
            Store.settings.set(pack.page, forKey: "dev.pack.page")
        }
        page.state = pack.page ? .on : .off
        menu.addItem(page)
        let bodies = PageMenuItem("With What Requests Sent and Got") {
            pack.bodies.toggle()
            Store.settings.set(pack.bodies, forKey: "dev.pack.bodies")
        }
        bodies.state = pack.bodies ? .on : .off
        menu.addItem(bodies)
        return menu
    }

    // MARK: picking rows

    private func pick(_ issue: Issue, in shown: [Issue]) {
        focused = true
        let flags = NSEvent.modifierFlags
        picking.click(issue.id, in: shown.map(\.id), shift: flags.contains(.shift), command: flags.contains(.command))
    }

    private func toggle(_ issue: Issue) {
        if open.contains(issue.id) { open.remove(issue.id) } else { open.insert(issue.id) }
    }

    /// ⌘C and the button: the rows picked, else what the list shows.
    private func copy(_ shown: [Issue]) {
        let picked = shown.filter { picking.picked.contains($0.id) }
        browser.copyIssues(picked.isEmpty ? shown : picked, on: tab)
    }

    private func selectionBar(_ shown: [Issue]) -> some View {
        let picked = shown.filter { picking.picked.contains($0.id) }
        return HStack(spacing: 8) {
            Text(picked.count == 1 ? "1 picked" : "\(picked.count) picked")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
                .padding(.leading, 4)
            CopySplit(copy: { browser.copyIssues(picked, on: tab) }, menu: { copyMenu(shown) })
            Button("Ask in Chat") { browser.askInChat(about: tab, selection: DevCopy.pack(picked, page: tab.address, size: tab.builtPage?.bounds.size)) }
                .buttonStyle(.yab(.secondary, .small))
            Button { picking.none() } label: { Symbol("xmark", size: 11) }
                .buttonStyle(.yab(.quiet, .small, icon: .square))
                .keyTip("Pick None", keys: "esc")
        }
        .focusable(false)
        .cardFrame()
    }
}

/// The list's bar: the search, the filters after it, and from the right edge
/// what copies, on one row while the search keeps `least` there. With less
/// room, as Chromium's Network bar wraps, the search and what copies take the
/// first row and the filters go under them. An HStack of them was wider
/// than the card beside the page, and SwiftUI cut it at both edges, the
/// rows under it too.
private struct IssueBar: Layout {
    enum Place {
        case search, filter, end
    }

    struct Role: LayoutValueKey {
        static let defaultValue = Place.end
    }

    static let spacing: CGFloat = 4
    /// The least air between the filters and what copies.
    static let gap: CGFloat = 8
    /// The least the search keeps on one row.
    static let least: CGFloat = 120

    private struct Rows {
        var one: Bool
        var search: CGFloat
        var first: CGFloat
        var second: CGFloat
        var whole: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(proposal.width, subviews)
        return CGSize(width: proposal.width ?? rows.whole, height: rows.one ? rows.first : rows.first + Self.spacing + rows.second)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(bounds.width, subviews)
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let top = bounds.minY + rows.first / 2
        var edge = bounds.maxX
        for index in subviews.indices.reversed() where subviews[index][Role.self] == .end {
            subviews[index].place(at: CGPoint(x: edge, y: top), anchor: .trailing, proposal: ProposedViewSize(sizes[index]))
            edge -= sizes[index].width + Self.spacing
        }
        var x = bounds.minX
        for index in subviews.indices where subviews[index][Role.self] == .search {
            subviews[index].place(at: CGPoint(x: x, y: top), anchor: .leading, proposal: ProposedViewSize(width: rows.search, height: sizes[index].height))
            x += rows.search + Self.spacing
        }
        let y = rows.one ? top : bounds.minY + rows.first + Self.spacing + rows.second / 2
        if !rows.one { x = bounds.minX }
        for index in subviews.indices where subviews[index][Role.self] == .filter {
            subviews[index].place(at: CGPoint(x: x, y: y), anchor: .leading, proposal: ProposedViewSize(sizes[index]))
            x += sizes[index].width + Self.spacing
        }
    }

    private func rows(_ width: CGFloat?, _ subviews: Subviews) -> Rows {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        func run(_ place: Place) -> CGSize {
            let items = subviews.indices.filter { subviews[$0][Role.self] == place }
            return CGSize(width: items.reduce(0) { $0 + sizes[$1].width } + Self.spacing * CGFloat(max(0, items.count - 1)),
                          height: items.map { sizes[$0].height }.max() ?? 0)
        }
        let search = run(.search), filters = run(.filter), end = run(.end)
        // All on the row but the search.
        let rest = Self.spacing + filters.width + Self.gap + end.width
        let whole = search.width + rest
        let room = width ?? whole
        if room - rest >= min(search.width, Self.least) {
            return Rows(one: true, search: min(search.width, room - rest), first: max(search.height, filters.height, end.height), second: 0, whole: whole)
        }
        return Rows(one: false, search: max(0, room - Self.spacing - end.width), first: max(search.height, end.height), second: filters.height, whole: whole)
    }
}

// MARK: - a row

/// A row as Chromium's console draws one: the level's ground and ink, its
/// mark, ▶ for what is under it, the words in a fixed-width face, a count,
/// and where it was said on the right.
private struct IssueRow: View, Equatable {
    let issue: Issue
    let page: URL?
    let selected: Bool
    let open: Bool
    /// Rows are being picked: each shows its box.
    let checking: Bool
    let wide: Bool
    let pick: () -> Void
    /// Its box: this row in or out, the others as they are.
    let check: () -> Void
    let toggle: () -> Void
    let copy: () -> Void
    let reveal: (DevPlace) -> Void
    let inspect: () -> Void
    let network: () -> Void
    let curl: () -> Void
    @State private var hovering = false

    static func == (a: IssueRow, b: IssueRow) -> Bool {
        a.issue == b.issue && a.selected == b.selected && a.open == b.open && a.checking == b.checking && a.wide == b.wide && a.page == b.page
    }

    private var level: DevLog.Level? {
        if case .said(let entry) = issue { return entry.level }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                // Always in its place, seen under the pointer or while rows
                // are picked, so nothing moves as it comes; pressed even
                // unseen, as a column of boxes is.
                Button(action: check) {
                    // Unseen, the mark alone: a view SwiftUI draws at nothing
                    // takes no press, its frame still does.
                    Symbol(selected ? "checkmark.circle.fill" : "circle", size: 10)
                        .foregroundStyle(selected ? Color.accentColor : Palette.muted)
                        .opacity(checking || hovering ? 1 : 0)
                        .frame(width: 12, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyTip(selected ? "Unpick" : "Pick")
                mark.frame(width: 12).padding(.top, 2)
                Button(action: toggle) {
                    Symbol("chevron.right", size: 7, weight: .semibold)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 10, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyTip(open ? "Hide the Stack" : "Show the Stack")
                words
                    .frame(maxWidth: .infinity, alignment: .leading)
                // At the line's height, so the row doesn't grow as it
                // comes; an open row has it under its stack already.
                if hovering, !open {
                    Button("Copy for Agent", action: copy)
                        .buttonStyle(.yab(.raised, .small))
                        .frame(height: 14)
                }
                if let count, count > 1 {
                    Text(count.formatted())
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 6)
                        .background(Palette.ink.opacity(0.08), in: Capsule())
                        .padding(.top, 1)
                }
                source
            }
            .padding(.vertical, 4)
            .padding(.horizontal, DevLook.padding)
            .contentShape(Rectangle())
            .onTapGesture(perform: pick)
            if open { detail }
        }
        .background(ground)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(line).frame(height: 1) }
        .onHover { hovering = $0 }
        .focusable(false)
    }

    @ViewBuilder private var mark: some View {
        switch level {
        case .error?: Symbol("xmark.circle.fill", size: 10).foregroundStyle(DevLook.errorMark)
        case .warning?: Symbol("exclamationmark.triangle.fill", size: 10).foregroundStyle(DevLook.amber)
        case nil: Symbol("arrow.up.right", size: 9).foregroundStyle(DevLook.errorMark)
        }
    }

    @ViewBuilder private var words: some View {
        switch issue {
        case .said(let entry):
            Text(entry.text)
                .font(DevMono.font(11.5))
                .foregroundStyle(entry.level == .error ? DevLook.errorInk : DevLook.warningInk)
                .lineLimit(open ? 12 : 1)
                .truncationMode(.tail)
        case .request(let request):
            let path = URL(string: request.url).map { $0.path() + ($0.query().map { "?" + $0 } ?? "") } ?? request.url
            (Text(request.status == 0 ? "failed " : "\(request.status) ").foregroundStyle(DevLook.errorInk).fontWeight(.semibold)
             + Text("\(request.method) \(path) · \(request.ms) ms").foregroundStyle(Palette.ink))
                .font(DevMono.font(11.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var count: Int? {
        if case .said(let entry) = issue { return entry.count }
        return nil
    }

    @ViewBuilder private var source: some View {
        switch issue {
        case .said(let entry):
            if let place = DevLog.place(entry) {
                Button { reveal(place) } label: {
                    Text(place.short)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.accentColor)
                        .underline(color: Color.accentColor.opacity(0.35))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .keyTip("Show in Sources")
            }
        case .request(let request):
            Button(action: network) {
                Text(request.kind)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.accentColor)
                    .underline(color: Color.accentColor.opacity(0.35))
            }
            .buttonStyle(.plain)
            .keyTip("Show in Network")
        }
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch issue {
            case .said(let entry):
                let (own, all) = DevLog.frames(entry.stack)
                let shown = Array((own.isEmpty ? all : own).prefix(12))
                if shown.isEmpty, !entry.source.isEmpty {
                    Text("at " + DevLog.frame(entry.source, page: page))
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { _, frame in
                    Text("at " + DevLog.frame(frame, page: page))
                }
                if all.count > shown.count {
                    Text("… \(all.count - shown.count) more frames").foregroundStyle(Palette.muted)
                }
                HStack(spacing: 4) {
                    Button("Show in Console", action: inspect).buttonStyle(.yab(.secondary, .small))
                    Button("Copy for Agent", action: copy).buttonStyle(.yab(.primary, .small))
                }
                .padding(.top, 4)
            case .request(let request):
                Text(request.url).lineLimit(2).truncationMode(.middle)
                if let failure = request.failure { Text(failure).foregroundStyle(DevLook.errorInk) }
                if let body = request.requestBody, !body.isEmpty { Text("sent: " + body).lineLimit(3).foregroundStyle(Palette.muted) }
                if let body = request.responseBody, !body.isEmpty { Text("→ " + body).lineLimit(4).foregroundStyle(Palette.muted) }
                HStack(spacing: 4) {
                    Button("Copy as cURL", action: curl).buttonStyle(.yab(.secondary, .small))
                    Button("Copy for Agent", action: copy).buttonStyle(.yab(.primary, .small))
                }
                .padding(.top, 4)
            }
        }
        .font(DevMono.font(11))
        .foregroundStyle(level == .warning ? DevLook.warningInk : Palette.ink.opacity(0.8))
        .textSelection(.enabled)
        .padding(.leading, 52) // design: the stack stands under the row's words, past its box, mark and ▶
        .padding(.trailing, DevLook.padding)
        .padding(.bottom, 8)
        .focusable(false)
    }

    private var ground: Color {
        let base: Color = {
            switch level {
            case .error?: return DevLook.errorGround
            case .warning?: return DevLook.warningGround
            case nil: return .clear
            }
        }()
        return selected ? base.mix(with: Color.accentColor, by: 0.12) : base
    }

    private var line: Color {
        switch level {
        case .error?: return DevLook.errorLine
        case .warning?: return DevLook.warningLine
        case nil: return Palette.ink.opacity(0.05)
        }
    }
}

extension DevLook {
    private static func tone(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    /// Chrome's console colors, as WebKit's console in the card has them.
    static let errorGround = tone(light: NSColor(srgbRed: 1, green: 0.922, blue: 0.922, alpha: 1),
                                  dark: NSColor(srgbRed: 1, green: 0.25, blue: 0.25, alpha: 0.13))
    static let errorLine = tone(light: NSColor(srgbRed: 1, green: 0.847, blue: 0.847, alpha: 1),
                                dark: NSColor(srgbRed: 1, green: 0.3, blue: 0.3, alpha: 0.2))
    static let errorInk = tone(light: NSColor(srgbRed: 0.733, green: 0, blue: 0, alpha: 1),
                               dark: NSColor(srgbRed: 1, green: 0.55, blue: 0.52, alpha: 1))
    static let errorMark = tone(light: NSColor(srgbRed: 0.9, green: 0.1, blue: 0.08, alpha: 1),
                                dark: NSColor(srgbRed: 1, green: 0.4, blue: 0.38, alpha: 1))
    static let warningGround = tone(light: NSColor(srgbRed: 1, green: 0.98, blue: 0.878, alpha: 1),
                                    dark: NSColor(srgbRed: 1, green: 0.78, blue: 0.1, alpha: 0.1))
    static let warningLine = tone(light: NSColor(srgbRed: 0.96, green: 0.92, blue: 0.72, alpha: 1),
                                  dark: NSColor(srgbRed: 1, green: 0.78, blue: 0.1, alpha: 0.18))
    static let warningInk = tone(light: NSColor(srgbRed: 0.616, green: 0.247, blue: 0, alpha: 1),
                                 dark: NSColor(srgbRed: 0.96, green: 0.76, blue: 0.33, alpha: 1))
}

/// Rows picked, as Finder picks: a click one row alone (again, none), ⌘ one
/// in or out, ⇧ the run from where the last pick was made, in place of what
/// was picked; ⇧⌘ adds the run. The row's box is a ⌘-click.
struct IssuePicking: Equatable {
    var picked: Set<String> = []
    /// Where a ⇧-click's run starts.
    var anchor: String?

    mutating func click(_ id: String, in ids: [String], shift: Bool, command: Bool) {
        if shift, let anchor, let from = ids.firstIndex(of: anchor), let to = ids.firstIndex(of: id) {
            let run = Set(ids[min(from, to)...max(from, to)])
            picked = command ? picked.union(run) : run
        } else if command {
            toggle(id)
        } else {
            picked = picked == [id] ? [] : [id]
            anchor = id
        }
    }

    mutating func toggle(_ id: String) {
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
        anchor = id
    }

    /// Only what is still shown stays picked.
    mutating func keep(_ ids: [String]) {
        picked.formIntersection(ids)
        if let anchor, !ids.contains(anchor) { self.anchor = nil }
    }

    mutating func all(_ ids: [String]) {
        picked = Set(ids)
        if anchor == nil { anchor = ids.first }
    }

    mutating func none() {
        picked = []
        anchor = nil
    }
}

/// Copy for Agent as the small window's Open in <space> is drawn: its words
/// and ⌘C on one card, and behind a hairline a chevron whose menu says
/// what else to copy (SplitFace).
struct CopySplit: View {
    let copy: () -> Void
    let menu: () -> NSMenu
    @Environment(\.tone) private var tone
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    @State private var chevronHovering = false
    @State private var anchor = MenuAnchor.Holder()

    var body: some View {
        HStack(spacing: 0) {
            Button(action: copy) {
                HStack(spacing: 6) {
                    Text("Copy for Agent")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    // The plate 4 in from the button's edges, as a .yab's is.
                    KeyGlyphs(keys: "⌘C", size: 11.5, tint: Palette.muted(on: tone))
                        .environment(\.keyPlate, KeyPlate(height: ButtonSize.small.height - 2 * ButtonSize.small.keyInset, pull: 0, lead: ButtonSize.small.keyLead))
                }
                .modifier(LeadingRoom(padding: ButtonSize.small.padding))
                .padding(.trailing, ButtonSize.small.keyInset)
                .frame(height: ButtonSize.small.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: ButtonSize.small.pressed))
            .onHover { hovering = $0 }
            Rectangle()
                .fill(Palette.ink.opacity(0.1))
                .frame(width: 0.5, height: 16)
            Button {
                guard let view = anchor.view else { return }
                menu().popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
            } label: {
                Symbol("chevron.down", size: 8, weight: .semibold)
                    .foregroundStyle(chevronHovering ? Palette.ink : Palette.muted(on: tone))
                    .frame(width: 20, height: ButtonSize.small.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: ButtonSize.small.pressed))
            .background(MenuAnchor(holder: anchor))
            .onHover { chevronHovering = $0 }
            .keyTip("What to Copy")
        }
        .fixedSize()
        .modifier(SplitFace(lit: enabled && (hovering || chevronHovering)))
        .opacity(enabled ? 1 : 0.5)
        .focusable(false)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: chevronHovering)
    }
}

/// The view a menu pops up under: the chevron's own place in AppKit.
struct MenuAnchor: NSViewRepresentable {
    final class Holder {
        weak var view: NSView?
    }

    let holder: Holder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        holder.view = view
    }
}
