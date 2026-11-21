import AppKit
import SecurityInterface
import SwiftUI
import WebKit

// Site Controls, as Arc has them: one button for everything about the page
// in front, the sliders in a square at the end of the address, in the
// sidebar's plate or the band over the page; in the row of tabs with no
// band, no sliders, the panel hanging from the open tab's mark. What it
// opens is the panel ⌘E opens (ExtensionPanel), so an extension's popup still takes the panel's
// place: four things to do with the page; the extensions; what this site
// has been allowed, each said in a word and changed where it stands; and at
// the foot, the connection, which turns the panel to its own page, and the
// rarer things, behind "…".
//
// The address bar and Split View move the address out of the column.
// Developer Mode keeps the column's search plate alongside its workbench
// band, as Arc does (SidePlate).

/// Which of the panel's two pages is up.
enum SitePage {
    case main, connection
}

/// What the panel is showing, for the doors that open it to light up.
@MainActor
final class SiteControlsState: ObservableObject {
    static let shared = SiteControlsState()
    @Published var page: SitePage = .main
    /// The tab the panel is about, while it is up.
    @Published var openFor: Tab.ID?
    /// What was hidden on this site, listed under its row: opened from the
    /// row, or from ⌘K's Hidden Here.
    @Published var hiddenOpen = false
}

extension Browser {
    /// Developer Mode adds its workbench band without taking away the
    /// column's search plate. The explicit address bar and Split View
    /// still put the address over the page; Mail has its own column.
    var sidePlated: Bool { (windowPurpose == .privateOnly || !prefs.addressBar) && !splitShown && !inMail }

    /// The same choice for an incoming space, before it is selected.
    /// Its pins, rows and pictured plate must reserve the same room.
    func sidePlated(_ row: Parked?) -> Bool {
        guard windowPurpose == .privateOnly || !prefs.addressBar else { return false }
        guard let row, let id = row.active else { return true }
        return !row.pairs.contains { $0.first == id || $0.second == id }
    }
}

// MARK: - the panel

/// What the panel holds: the page's four things to do, the extensions, this
/// site, the connection at the foot.
struct SiteControlsView: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var prefs: Preferences
    @ObservedObject var translation: PageTranslation
    @ObservedObject var extensions: Extensions
    @ObservedObject var state = SiteControlsState.shared
    @ObservedObject private var shield = Shield.shared
    /// A Chromium tab's own extensions (ChromiumColumn).
    @ObservedObject private var column = ChromiumColumn.shared
    @ObservedObject private var automaticPiP = AutomaticPiPSites.shared
    /// Bumped when something here is forgotten, so the rows are read again.
    @State private var forgets = 0

    static let width: CGFloat = 280
    static let inset = ExtensionMenu.inset
    static var inner: CGFloat { ExtensionMenu.inner }
    /// A tile: an action's, an extension's.
    static let tile: CGFloat = 34

    private var facts: SiteFacts { SiteFacts(tab: tab) }
    /// Page tools that work on the row's tab in front, not on a page outside the row (a small window's).
    private var inRow: Bool { !browser.outside.contains { $0 === tab } }

    var body: some View {
        Group {
            switch state.page {
            case .main: main
            case .connection: connection
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // A blocker added and never answered for: asked once more, here.
        .onAppear { Blockers.askAgainIfOwed() }
        // Its own height, for the panel to follow (ExtensionPanel.follow).
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { ExtensionPanel.shared.follow($0, filter: "") }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.ground)
    }

    // MARK: the main page

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            actions
            if inRow { BoostSiteBlock(browser: browser, tab: tab) }
            extensionsBlock
            let rows = siteRows
            if !rows.isEmpty {
                heading("This site")
                // Ticking only while an off waits on an extension's rules.
                // The rows keep their identity through a press (forgets is
                // read in siteRows), so their icons animate (SiteControlsIcon).
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 1) {
                        ForEach(shield.waiting.isEmpty ? rows : siteRows) { row in SettingRow(row: row) }
                    }
                }
                // The list stays open through a restore.
                if state.hiddenOpen, !hidden.isEmpty {
                    HiddenList(browser: browser, curtain: browser.curtain) { forgets += 1 }
                        .padding(.top, 1)
                }
            }
            Divider().overlay(Palette.hairline).padding(.vertical, 6)
            HStack {
                if facts.isSite {
                    Pill(symbol: facts.secure ? "lock" : "lock.open", title: facts.connection.short, alarm: facts.connection.alarm) {
                        ExtensionPanel.shared.expect(.filtering)
                        state.page = .connection
                    }
                }
                Spacer(minLength: 0)
                more
            }
        }
        .padding(Self.inset)
    }

    /// Share, Capture, Hide Elements, and Reading Mode when the page has an
    /// article, Translate when it hasn't; Float Video on a site whose video
    /// is the point of it, or while its video is out.
    private var actions: some View {
        let url = tab.address
        let page = !tab.isBlank
        return HStack(spacing: 6) {
            if let url, Bookmark.keepable(url) {
                ShareLink(item: Diary.shareable(url)) {
                    TileFace(symbol: "square.and.arrow.up")
                }
                .buttonStyle(Door.Give())
                .keyTip("Share Page")
            } else {
                TileFace(symbol: "square.and.arrow.up", dim: true)
            }
            Tile(symbol: "camera", tip: "Capture", shortcut: "Capture…", enabled: page && inRow) {
                ExtensionPanel.shared.close()
                browser.capture.start()
            }
            Tile(symbol: "eye.slash", tip: "Hide Elements", shortcut: "Hide Elements…", enabled: page && inRow) {
                ExtensionPanel.shared.close()
                browser.toggleHiding()
            }
            if tab.readable {
                Tile(symbol: "book.open", tip: "Reading Mode", shortcut: "Reading Mode", enabled: page && inRow) {
                    ExtensionPanel.shared.close()
                    browser.toggleReader(tab)
                }
            } else {
                Tile(symbol: "translate", tip: translationTitle, enabled: page && facts.isSite) {
                    ExtensionPanel.shared.close()
                    translation.toggle(tab)
                }
            }
            if inRow, Players.knows(url) || browser.floating == tab.id {
                Tile(symbol: "pip", tip: "Float Video", shortcut: "Float Video", enabled: page) {
                    ExtensionPanel.shared.close()
                    browser.toggleFloat()
                }
            }
        }
    }

    /// Every extension with a button, the pinned first, and one more square
    /// for the store. Pressed, its popup takes the panel's place.
    private var extensionsBlock: some View {
        // The extension blocking ads has its button at the end of "Block
        // ads and trackers" instead.
        let blocking = shield.blocker(persistent: tab.store.isPersistent)
        // The pinned in their own order (a sort isn't stable, and shuffled them).
        let chromium = tab.engineKind == .chromium
        let all = chromium ? column.buttons(for: tab, all: true) : extensions.buttons.filter { $0.id != blocking }
        let buttons = all.filter(\.pinned) + all.filter { !$0.pinned }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Extensions").sidebarFont(size: 12, weight: .semibold).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                if chromium ? !all.isEmpty : !extensions.installed.isEmpty {
                    Button("Manage") {
                        if chromium {
                            ExtensionPanel.shared.close()
                            (tab.delegate as? Browser)?.openSettings(.extensions)
                        } else { ExtensionMenu.manage(extensions) }
                    }
                        .buttonStyle(.plain)
                        .sidebarFont(size: 12)
                        .foregroundStyle(Palette.muted)
                        .focusable(false)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(buttons) { button in
                    ExtensionTile(button: button, extensions: extensions, native: chromium ? tab : nil)
                }
                Tile(symbol: "plus", tip: "Chrome Web Store") {
                    ExtensionPanel.shared.close()
                    browser.open(Browser.webStore, foreground: true)
                }
            }
        }
    }

    // MARK: this site

    struct Setting: Identifiable {
        var id: String { title }
        let symbol: String
        let title: String
        let said: String
        var on = false
        /// On, turning off: the mark off already, dimmed until it is.
        var dim = false
        var live = false
        var act: (() -> Void)?
        var end: AnyView?
        /// Pressing the row opens this menu's lines instead of acting.
        var menu: AnyView?
    }

    /// Only what there is something to say about: the blocker while it is
    /// on, Developer Mode on this Mac's own servers, zoom when it isn't
    /// 100%, the camera and microphone while they are in use, and what this
    /// site was once allowed or refused.
    private var siteRows: [Setting] {
        guard facts.isSite else { return [] }
        _ = forgets
        var rows: [Setting] = []
        let site = facts.site
        if prefs.shielded, shield.trouble == nil {
            let paused = shield.isPaused(on: site)
            let blocking = shield.blocker(persistent: tab.store.isPersistent)
            let said = SiteControlsView.blockSaid(site: site, paused: paused, persistent: tab.store.isPersistent)
            rows.append(Setting(symbol: paused ? "xmark.shield" : "checkmark.shield", title: "Block ads and trackers",
                                said: said, on: !paused, dim: paused && shield.waiting[site] != nil,
                                act: { [browser, tab] in
                                    browser.switchBlocking(site, on: tab)
                                    forgets += 1
                                },
                                end: blocking.map { id in AnyView(BlockerSettings(id: id, extensions: extensions)) }))
        }
        // Dark pages, while pages can be dark here (DarkPages.swift).
        if let row = darkRow(site) { rows.append(row) }
        // Opens in, only while the engine is not the one this window would use.
        if let row = opensInRow(done: { forgets += 1 }) { rows.append(row) }
        if let row = Self.automaticPiPRow(url: tab.address, globally: prefs.floatsOnLeave, sites: automaticPiP) {
            rows.append(row)
        }
        if tab.canDev {
            rows.append(Setting(symbol: "chevron.left.forwardslash.chevron.right", title: "Developer Mode",
                                said: tab.isDev ? "On" : "Off", on: tab.isDev) { [browser, tab] in
                browser.setDevMode(tab, !tab.isDev)
                forgets += 1
            })
        }
        if abs(tab.zoom - 1) > 0.004 {
            rows.append(Setting(symbol: "plus.magnifyingglass", title: "Zoom", said: "\(Int((tab.zoom * 100).rounded()))%",
                                act: { [tab] in tab.resetZoom() },
                                end: AnyView(Stepper(tab: tab))))
        }
        let camera = tab.camera == .active, microphone = tab.microphone == .active
        if camera || microphone {
            let title = camera && microphone ? "Camera and microphone" : camera ? "Camera" : "Microphone"
            rows.append(Setting(symbol: camera ? "video" : "mic", title: title, said: "In use now", live: true))
        }
        for allowed in facts.allowed {
            rows.append(Setting(symbol: allowed.symbol, title: allowed.title, said: allowed.said ? "Allowed" : "Blocked",
                                end: AnyView(Forget { allowed.forget(); forgets += 1 })))
        }
        if case .translated = translation.phase(for: tab) {
            rows.append(Setting(symbol: "translate", title: "Translated", said: "To \(translation.targetName(for: tab))", on: true) { [translation, tab] in
                translation.toggle(tab)
            })
        }
        // What Hide Elements took off this site, listed under the row.
        let veils = inRow ? hidden : []
        if !veils.isEmpty {
            let open = state.hiddenOpen
            rows.append(Setting(symbol: "eye.slash", title: "Hidden here", said: veils.count == 1 ? "1 part" : "\(veils.count) parts",
                                act: { [state] in state.hiddenOpen.toggle() },
                                end: AnyView(Symbol(open ? "chevron.up" : "chevron.down", size: 10, weight: .medium)
                                    .foregroundStyle(Palette.muted)
                                    .frame(width: 24, height: 24))))
        }
        return rows
    }

    /// Approved #647 A: an ordinary This site row, with the master switch
    /// dominant. Off globally keeps the site's saved exception intact.
    static func automaticPiPRow(url: URL?, globally: Bool, sites: AutomaticPiPSites) -> Setting? {
        guard let site = AutomaticPiPSites.site(url) else { return nil }
        let allowed = sites.allows(url)
        return Setting(symbol: "pip", title: "Automatic Picture in Picture",
                       said: globally ? "\(allowed ? "On" : "Off") for \(IDN.shown(site))" : "Off in Settings › Tabs",
                       on: globally && allowed, dim: !globally,
                       act: globally ? { sites.setAllowed(!sites.allows(url), for: url) } : nil)
    }

    /// Dark page: on, the site's own, or off here; or Dark Reader the
    /// extension doing it, with Yab's own a press away.
    private func darkRow(_ site: String) -> Setting? {
        guard DarkPages.active(windowDark: DarkPages.windowDark(for: tab), mode: prefs.darkPages), !tab.bench else { return nil }
        if extensions.installed.contains(where: { $0.id == DarkPages.extensionID && $0.enabled }) {
            return Setting(symbol: "moon", title: "Dark page", said: "Dark Reader does it here",
                           end: AnyView(Button("Use Yab\u{2019}s") { DarkPages.takeOverFromExtension(); forgets += 1 }
                            .buttonStyle(.yab(.secondary, .small))))
        }
        let said: String
        switch tab.dark {
        case .engine: said = "On"
        case .own: said = "The site\u{2019}s own"
        case .off: said = "Off on \(site)"
        // Dark pages Off in a dark window: the row is there to turn this one site on.
        case .none:
            guard prefs.darkPages == .off, DarkPages.eligible(tab, url: tab.address) else { return nil }
            said = "Off"
        case .extensionDoes: return nil
        }
        return Setting(symbol: "moon", title: "Dark page", said: said, on: tab.dark == .engine || tab.dark == .own) { [browser, tab] in
            browser.toggleDarkPage(tab)
            forgets += 1
        }
    }

    /// Who blocks here, in the row's subtitle: the source, the countdown
    /// while an off waits on an extension's rules, the site when off.
    static func blockSaid(site: String, paused: Bool, persistent: Bool, now: Date = Date()) -> String {
        let shield = Shield.shared
        if paused {
            guard let left = Blockers.left(site, now: now) else { return "Off on \(site)" }
            return left < 0 || left < 1 ? "Off in a few seconds" : "Off in \(Int(left.rounded(.up))) s"
        }
        guard let chosen = shield.chosen else { return "On" }
        let name = Blockers.name(chosen)
        if shield.blocker(persistent: persistent) == chosen { return "On · \(name)" }
        if shield.source == .extension(chosen), !persistent { return "On · Yab in private tabs" }
        if shield.failed == nil, Extensions.shared.contexts[chosen] != nil { return "On · Yab until \(name) is ready" }
        return "On"
    }

    /// What was hidden on this page's site.
    private var hidden: [Veil] {
        _ = forgets
        return browser.curtain.veils(on: browser.curtain.host(of: tab.address))
    }

    /// What was hidden here, one row each, under the Hidden Here row. A
    /// selector is not something anyone can read, so the pointer resting on
    /// a row puts that one thing back on the page, outlined and scrolled to:
    /// it is told by looking, not by its name. Restore brings it back for
    /// good. Leaving the list, or the panel, puts the page back as it was.
    private struct HiddenList: View {
        let browser: Browser
        @ObservedObject var curtain: Curtain
        let changed: () -> Void

        var body: some View {
            let veils = curtain.veils(on: browser.hereHost)
            VStack(spacing: 1) {
                ForEach(veils) { veil in
                    HiddenRow(veil: veil, peek: { browser.peek(veil) }) {
                        browser.restore(veil)
                        changed()
                    }
                }
                if veils.count > 1 {
                    HStack(spacing: 10) {
                        Color.clear.frame(width: 28, height: 1)
                        Button("Restore All") {
                            browser.restoreAll()
                            changed()
                        }
                        .buttonStyle(.yab(.quiet, .small))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
            }
            .onHover { inside in
                if !inside { browser.stopPeeking() }
            }
            // The panel closing closes the list too (ExtensionPanel).
            .onDisappear { browser.stopPeeking() }
        }
    }

    /// One thing hidden: what it was, in words, and its size and place, the
    /// words standing under the row's own. Restore is there from the start,
    /// unseen until the pointer is on the row, so nothing moves.
    private struct HiddenRow: View {
        let veil: Veil
        let peek: () -> Void
        let restore: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                Color.clear.frame(width: 28, height: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(veil.label).sidebarFont(size: 12.5).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.tail)
                    if let note = veil.note, !note.isEmpty {
                        Text(note).sidebarFont(size: 11.5).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button("Restore", action: restore)
                    .buttonStyle(.yab(.secondary, .small))
                    .focusable(false)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: SiteControlsView.inner - 4, style: .continuous)
                .fill(hovering ? Palette.hover : .clear))
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { peek() }
            }
        }
    }

    private var translationTitle: String {
        switch translation.phase(for: tab) {
        case .original, .failed: "Translate to \(translation.targetName)"
        case .preparing, .translating: "Stop Translating"
        case .translated: "Show Original"
        }
    }

    // MARK: the rarer things

    private var more: some View {
        Menu {
            if facts.isSite {
                Button("Clear Cookies and Data for \(IDN.shown(facts.site))…", mark: "yab.cookie") { clearData() }
                Button(translationTitle, mark: "yab.translate") { translation.toggle(tab) }
                Button("Copy Markdown Link", mark: "markdown") {
                    // A small window says it in its own corner.
                    if let link = LinkWindow.all.first(where: { $0.tab === tab }) { link.copyPage(markdown: true) }
                    else { browser.copyMarkdownLink([tab]) }
                }
                // Send to <iPhone>, for each iPhone that takes pages (SyncPhone).
                PhoneSend(browser: browser, tab: tab)
                if tab.offersSiteEngine { OpensInMenu(tab: tab) { forgets += 1 } }
                Divider()
            }
            Button("Manage Extensions…", mark: "puzzlepiece.extension") { ExtensionMenu.manage(extensions) }
            Button("Chrome Web Store…", mark: "storefront") {
                ExtensionPanel.shared.close()
                browser.open(Browser.webStore, foreground: true)
            }
            Button("Load Unpacked…", mark: "yab.folder.plus") {
                ExtensionPanel.shared.close()
                DispatchQueue.main.async { extensions.installFolder() }
            }
            Divider()
            Button("All Site Settings…", mark: "yab.globe") {
                ExtensionPanel.shared.close()
                browser.openSettings(.privacy)
            }
        } label: {
            Symbol("ellipsis", size: 11, weight: .medium)
                .foregroundStyle(Palette.muted)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .keyTip("More")
    }

    /// Everything this site keeps on this Mac, after a yes: the cookies go
    /// with it, so it signs you out.
    private func clearData() {
        let site = facts.site
        ExtensionPanel.shared.close()
        Task { @MainActor in
            let question = Question(
                title: "Clear data for \(IDN.shown(site))?",
                detail: "Its cookies, storage and cache on this Mac go, so you'll be signed out of it. Other sites keep theirs.",
                glyph: "broom", yes: "Clear", danger: true, place: .plain
            )
            guard await Questions.shared.ask(question) else { return }
            await browser.forgetSite(site, tab: tab)
            browser.reload(tab)
        }
    }

    // MARK: the connection's page

    private var connection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                ExtensionPanel.shared.expect(.filtering)
                state.page = .main
            } label: {
                HStack(spacing: 4) {
                    Symbol("chevron.left", size: 10, weight: .medium)
                    Text(IDN.shown(facts.site)).lineLimit(1).truncationMode(.head)
                }
                .sidebarFont(size: 12)
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Symbol(facts.secure ? "lock" : "lock.open", size: 11, weight: .medium)
                        .foregroundStyle(facts.connection.alarm ? Color.red.opacity(0.85) : Palette.ink)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Palette.wash))
                    Text(facts.connection.title)
                        .sidebarFont(size: 13, weight: .semibold)
                        .foregroundStyle(facts.connection.alarm ? Color.red.opacity(0.85) : Palette.ink)
                }
                Text(facts.connection.detail)
                    .sidebarFont(size: 12)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)

            if let trust = facts.trust {
                Divider().overlay(Palette.hairline).padding(.vertical, 6)
                SettingRow(row: Setting(symbol: "doc.text", title: "Show Certificate", said: "") {
                    ExtensionPanel.shared.close()
                    guard let window = tab.builtPage?.window ?? NSApp.keyWindow else { return }
                    SFCertificatePanel.shared().beginSheet(
                        for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust, showGroup: true
                    )
                })
            }
        }
        .padding(Self.inset)
    }

    // MARK: pieces

    private func heading(_ title: String) -> some View {
        Text(title)
            .sidebarFont(size: 12, weight: .semibold)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    /// A row of this site: a round icon, the name, what it is now in a word.
    /// The icon is filled while the thing is on. Pressed, it changes.
    struct SettingRow: View {
        let row: Setting
        @State private var hovering = false

        var body: some View {
            if let menu = row.menu {
                Menu { menu } label: { content }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .focusable(false)
                    .onHover { hovering = $0 }
            } else {
                content
                    .onTapGesture { row.act?() }
                    .onHover { hovering = $0 }
            }
        }

        private var content: some View {
            HStack(spacing: 10) {
                SiteControlsIcon(symbol: row.symbol, on: row.on, live: row.live)
                    .opacity(row.dim ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).sidebarFont(size: 12.5, weight: .medium).foregroundStyle(Palette.ink).lineLimit(1)
                    if !row.said.isEmpty {
                        Text(row.said).sidebarFont(size: 11.5).foregroundStyle(row.live ? Color.red.opacity(0.85) : Palette.muted)
                            // "On · Yab until uBlock Origin Lite is ready" takes two.
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if let end = row.end { end }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: SiteControlsView.inner - 4, style: .continuous)
                .fill(hovering && (row.act != nil || row.menu != nil) ? Palette.hover : .clear))
            .contentShape(Rectangle())
        }
    }

    /// Smaller and bigger, for a page that isn't at 100%.
    private struct Stepper: View {
        @ObservedObject var tab: Tab

        var body: some View {
            HStack(spacing: 2) {
                Small(symbol: "minus.magnifyingglass") { tab.stepZoom(increasing: false) }
                Small(symbol: "plus.magnifyingglass") { tab.stepZoom(increasing: true) }
            }
        }
    }

    /// The blocking extension's own button at the row's end: its popup.
    private struct BlockerSettings: View {
        let id: String
        let extensions: Extensions
        @State private var hovering = false

        var body: some View {
            Button { ExtensionPanel.shared.press(id) } label: {
                Group {
                    if let icon = extensions.icon(for: id, side: 14) {
                        Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        Symbol("puzzlepiece.extension", size: 10, weight: .medium).foregroundStyle(Palette.muted)
                    }
                }
                .frame(width: 14, height: 14)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(hovering ? Palette.hover : Palette.wash))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { hovering = $0 }
            .keyTip("\(Blockers.name(id))'s Settings")
        }
    }

    /// The small cross at a row's end: forgotten, and the site asks again.
    private struct Forget: View {
        let act: () -> Void

        var body: some View {
            Small(symbol: "xmark", act: act).keyTip("Forget, and ask again")
        }
    }

    struct Small: View {
        let symbol: String
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                Symbol(symbol, size: 10, weight: .medium)
                    .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(hovering ? Palette.hover : Palette.wash))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { hovering = $0 }
        }
    }

    /// The connection, in a word, at the panel's foot: pressed, its page.
    private struct Pill: View {
        let symbol: String
        let title: String
        let alarm: Bool
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                HStack(spacing: 6) {
                    Symbol(symbol, size: 10, weight: .medium)
                    Text(title).sidebarFont(size: 12, weight: .medium)
                }
                .foregroundStyle(alarm ? Color.red.opacity(0.85) : Palette.ink)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(hovering ? Palette.hover : Palette.wash))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { hovering = $0 }
        }
    }
}

/// A square of the panel's: an action's glyph.
struct TileFace: View {
    let symbol: String
    var dim = false
    var hovering = false

    var body: some View {
        Symbol(symbol, size: 12, weight: .medium)
            .foregroundStyle(dim ? Palette.faint : Palette.ink)
            .frame(maxWidth: .infinity)
            .frame(height: SiteControlsView.tile)
            .background(RoundedRectangle(cornerRadius: SiteControlsView.inner, style: .continuous).fill(hovering ? Palette.hover : Palette.wash))
            .contentShape(RoundedRectangle(cornerRadius: SiteControlsView.inner, style: .continuous))
    }
}

private struct Tile: View {
    let symbol: String
    let tip: String
    var shortcut: String?
    var enabled = true
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            TileFace(symbol: symbol, dim: !enabled, hovering: hovering && enabled)
        }
        .buttonStyle(Door.Give())
        .focusable(false)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .keyTip(tip, shortcut: shortcut)
    }
}

/// An extension in the panel: its icon on a square, a pin in the corner for
/// a pinned one. Pressed, its popup takes the panel; right-clicked, what can
/// be done with it.
private struct ExtensionTile: View {
    let button: Extensions.Button
    let extensions: Extensions
    /// A Chromium tab's native extension (ChromiumColumn).
    var native: Tab? = nil
    @State private var hovering = false

    var body: some View {
        Button {
            if let native {
                ChromiumColumn.shared.press(button.id, tab: native, list: ExtensionPanel.shared.handOver())
            } else { ExtensionPanel.shared.press(button.id) }
        } label: {
            ExtensionIcon(button: button, size: 18)
                .frame(width: 22, height: 22)
                .frame(maxWidth: .infinity)
                .frame(height: SiteControlsView.tile)
                .background(RoundedRectangle(cornerRadius: SiteControlsView.inner, style: .continuous).fill(hovering ? Palette.hover : Palette.wash))
                // The pin up in the corner: the badge, a count or "!", is
                // on the icon's foot, where toolbars usually put it, and sat
                // over the pin when both were down there.
                .overlay(alignment: .topTrailing) {
                    if button.pinned {
                        Symbol("pin.fill", size: 6.5)
                            .foregroundStyle(Palette.muted)
                            .padding(4)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: SiteControlsView.inner, style: .continuous))
        }
        .buttonStyle(Door.Give())
        .focusable(false)
        .onHover {
            hovering = $0
            // Its menu's own rows, read before a right click asks for them.
            if $0, let native { ChromiumActionMenu.shared.refresh(button.id, tab: native) }
        }
        .keyTip(button.label, keys: button.keys)
        .steadyMenu(actions: true) {
            if let native { ChromiumPinActions(id: button.id, name: button.name, tab: native) }
            else { ExtensionActions(id: button.id, name: button.name, extensions: extensions) }
        }
        // A pinned one dragged onto another pinned one takes its place, in
        // the plate and the extensions menu too, so toolbar buttons can be
        // reordered.
        .modifier(PinnedOrder(button: button, extensions: extensions))
    }
}

/// Dragging pinned extensions into another order (Extensions.movePinned).
private struct PinnedOrder: ViewModifier {
    let button: Extensions.Button
    let extensions: Extensions

    func body(content: Content) -> some View {
        if button.pinned {
            content
                .draggable(button.id)
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first, id != button.id,
                          extensions.installed.first(where: { $0.id == id })?.pinned == true
                    else { return false }
                    withAnimation(ExtensionMenu.pinning) { extensions.movePinned(id, to: button.id) }
                    return true
                }
        } else {
            content
        }
    }
}

// MARK: - what is known about the site

/// The page's site, its connection said in words, and what it was allowed.
@MainActor
struct SiteFacts {
    let tab: Tab

    var url: URL? { tab.address }
    var host: String { url?.host()?.lowercased() ?? "" }
    var site: String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
    var isSite: Bool {
        let scheme = url?.scheme?.lowercased()
        return (scheme == "https" || scheme == "http") && !host.isEmpty
    }
    var secure: Bool { url?.scheme?.lowercased() == "https" || Dialogs.isLoopback(host) }
    var trust: SecTrust? {
        guard url?.scheme?.lowercased() == "https" else { return nil }
        if let chromium = tab.builtPage as? ChromiumPage { return chromium.serverTrust }
        return tab.webKitOnly("Native certificate trust", build: false)?.serverTrust
    }

    struct Connection {
        let title: String
        /// The foot's word for it.
        let short: String
        let detail: String
        var alarm = false
    }

    var connection: Connection {
        let scheme = url?.scheme?.lowercased()
        if scheme == "https", let trust, !SecTrustEvaluateWithError(trust, nil) {
            return Connection(
                title: "Certificate not trusted", short: "Not trusted",
                detail: "This Mac doesn't trust the site's certificate. You went on anyway, so someone could be standing in for it.",
                alarm: true
            )
        }
        if Dialogs.isLoopback(host) {
            return Connection(title: "This Mac", short: "This Mac", detail: "The page comes from this Mac itself. Nothing on the way leaves it.")
        }
        if scheme == "http" {
            return Connection(
                title: "Not secure", short: "Not secure",
                detail: "Anything you send here, passwords and card numbers too, can be read on the way. Don't sign in or pay on this site.",
                alarm: true
            )
        }
        var detail = "Passwords and card numbers you send here are encrypted on the way, and only this site can read them."
        if let trust, let signed = Self.signed(trust) { detail += " " + signed }
        return Connection(title: "Connection is secure", short: "Secure", detail: detail)
    }

    /// Who signed the certificate and until when, as a sentence.
    private static func signed(_ trust: SecTrust) -> String? {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return nil }
        let keys = [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(leaf, keys, nil) as? [String: [String: Any]] else { return nil }
        var issuer: String?
        if let fields = values[kSecOIDX509V1IssuerName as String]?[kSecPropertyKeyValue as String] as? [[String: Any]] {
            let by = { (oid: CFString) in
                fields.first { ($0[kSecPropertyKeyLabel as String] as? String) == oid as String }?[kSecPropertyKeyValue as String] as? String
            }
            issuer = by(kSecOIDOrganizationName) ?? by(kSecOIDCommonName)
        }
        var until: Date?
        if let seconds = values[kSecOIDX509V1ValidityNotAfter as String]?[kSecPropertyKeyValue as String] as? NSNumber {
            until = Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
        }
        let date = until.map { $0.englishFormatted(date: .abbreviated, time: .omitted) }
        switch (issuer, date) {
        case let (issuer?, date?): return "Certificate from \(issuer), valid until \(date)."
        case let (issuer?, nil): return "Certificate from \(issuer)."
        case let (nil, date?): return "Certificate valid until \(date)."
        default: return nil
        }
    }

    struct Allowed {
        let symbol: String
        let title: String
        let said: Bool
        let forget: () -> Void
    }

    /// Only what was remembered: a site that never asked has no rows.
    var allowed: [Allowed] {
        var rows: [Allowed] = []
        let origin = Browser.origin(of: url)
        let capture: [(PageCapture, String, String)] = [
            (.camera, "video", "Camera"),
            (.microphone, "mic", "Microphone"),
            (.cameraAndMicrophone, "video", "Camera and microphone"),
        ]
        for (type, symbol, title) in capture {
            let keys = [origin.map { Browser.captureKey($0, type) }, Browser.captureKey(host, type)].compactMap { $0 }
            guard let said = keys.lazy.compactMap({ Store.settings.object(forKey: $0) as? Bool }).first else { continue }
            rows.append(Allowed(symbol: symbol, title: title, said: said) {
                keys.forEach(Store.settings.removeObject)
            })
        }
        let locationKeys = [origin.map(Browser.locationKey), Browser.locationKey(host)].compactMap { $0 }
        if let said = locationKeys.lazy.compactMap({ Store.settings.object(forKey: $0) as? Bool }).first {
            rows.append(Allowed(symbol: "location", title: "Location", said: said) {
                locationKeys.forEach(Store.settings.removeObject)
            })
        }
        if let origin, let said = SiteNotices.said(origin) {
            rows.append(Allowed(symbol: "bell", title: "Notifications", said: said) { SiteNotices.forget(origin) })
        }
        for kind in SitePermission.allCases where kind.remembered {
            guard let origin, let said = SitePermission.said(origin, kind) else { continue }
            rows.append(Allowed(symbol: kind.symbol, title: kind.title, said: said) { SitePermission.forget(origin, kind) })
        }
        for (kind, title) in [(LocalNetwork.Kind.loopback, "Apps on this Mac"), (.local, "Devices on your network")] {
            guard let origin, let said = LocalNetwork.said(origin, kind) else { continue }
            rows.append(Allowed(symbol: "devices", title: title, said: said) { LocalNetwork.forget(origin, kind) })
        }
        if WindowGate.allows(site) {
            rows.append(Allowed(symbol: "macwindow", title: "Windows", said: true) { [site] in WindowGate.forget(site) })
        }
        // More files than a click asks for: "Automatic downloads".
        if let said = SiteDownloads.many(for: host) {
            rows.append(Allowed(symbol: "arrow.down.to.line", title: "Automatic downloads", said: said) { [host] in SiteDownloads.forgetMany(host) })
        }
        return rows
    }
}

// MARK: - the door

/// The sliders in a square: Site Controls for `tab`. Lit while its panel is
/// up for this tab; a dot while a pinned extension has a count to show and
/// isn't standing anywhere to show it. It is also where ⌘E's panel hangs.
/// While the site has the camera or the microphone, it says so in the
/// sliders' place, in red: the panel it opens is where they are turned off.
struct SiteControlsDoor: View {
    let browser: Browser
    let tab: Tab?
    /// "video" or "mic", in use by the site now.
    var live: String?
    /// The plate's door is the plate's height less its air, with the
    /// plate's corner less that air.
    var side: CGFloat = Door.side
    var corner: CGFloat = Radius.control
    var glyph: CGFloat = 11.5
    /// The sliders' line, the weight of the doors beside them: the band's
    /// camera and the plate's link.
    var stroke: CGFloat = 1.5
    @ObservedObject private var state = SiteControlsState.shared
    /// The window's sign-in's extensions (ExtensionSignIns).
    @ObservedObject private var here = ExtensionsHere.shared
    @ObservedObject private var nativePopup = ChromiumPopupHost.shared
    private var extensions: Extensions { Extensions.of(browser, page: tab) }
    @Environment(\.tone) private var tone
    @State private var hovering = false
    @State private var box = ViewBox()

    var body: some View {
        // Lit while its panel is up, and while an extension's popup pressed
        // in the panel hangs from it in the panel's place.
        let hung: Bool = {
            guard #available(macOS 15.4, *) else { return false }
            if let tab, tab.engineKind == .chromium { return nativePopup.shownFromDoor(for: tab) }
            return ExtensionPopup.shared.hangs(from: box.view)
        }()
        let open = (state.openFor != nil && state.openFor == tab?.id && extensions.menuOpen) || hung
        Button {
            if let tab, browser.active?.id != tab.id { browser.focus(tab) }
            ExtensionPanel.shared.toggle(tab: tab, browser: browser, page: .main, from: box.view)
        } label: {
            Symbol(live ?? "slider.horizontal.2.square", size: live == nil ? glyph : glyph - 1, weight: .medium,
                   stroke: live == nil ? stroke : nil)
                .foregroundStyle(live != nil ? Color.red : open || hovering ? Palette.ink : Palette.muted(on: tone))
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(live != nil ? Color.red.opacity(open || hovering ? 0.24 : 0.16)
                          : open ? Palette.wash(on: tone) : hovering ? Palette.hover(on: tone) : .clear))
                .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(Door.Give())
        .focusable(false)
        .onHover { hovering = $0 }
        .keyTip(live == "video" ? "Camera in use" : live == "mic" ? "Microphone in use" : "Site Controls", shortcut: "Site Controls")
        .overlay(alignment: .topTrailing) {
            if !open, live == nil, extensions.dotted {
                Circle().fill(Palette.ink).frame(width: 5, height: 5).offset(x: -4, y: 4).allowsHitTesting(false)
            }
        }
        .background(PanelAnchor(box: box))
        .background {
            if let tab, tab.engineKind == .chromium { ChromiumPopupAnchor(id: ChromiumPopupAnchor.sliders, tab: tab) }
        }
    }
}

/// Holds the door's own view, for its panel to hang from.
final class ViewBox {
    weak var view: NSView?
}

/// A real view under the door: the panel's anchor, ⌘E's too.
struct PanelAnchor: NSViewRepresentable {
    let box: ViewBox
    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView(id: Extensions.menuAnchor, edge: .maxY)
        box.view = view
        return view
    }
    func updateNSView(_ view: AnchorView, context: Context) { box.view = view }
}

/// An extension's own anchor, for its popup to hang from the plate.
struct ExtensionAnchor: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> AnchorView { AnchorView(id: id, edge: .maxY) }
    func updateNSView(_ view: AnchorView, context: Context) {}
}

// MARK: - the plate

/// The address at the top of the column, over the pins, as Arc has it: the
/// site alone at rest, as wide as the plate. With the pointer in the column
/// the link and the sliders fade in over its end, the site fading out under
/// them, so nothing moves, and the pinned extensions come in before them,
/// all leaving together. A camera or microphone in use takes
/// the sliders' place, the blocker off here has its shield. Pressed, the
/// site is ⌘L.
struct SidePlate: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var here = ExtensionsHere.shared
    private var extensions: Extensions { space.map { Extensions.of(space: $0) } ?? Extensions.of(browser) }
    /// A Chromium tab's own extensions (ChromiumColumn).
    @ObservedObject private var column = ChromiumColumn.shared
    @ObservedObject private var nativePopup = ChromiumPopupHost.shared
    @ObservedObject private var shield = Shield.shared
    /// The pointer is somewhere in the column.
    let near: Bool
    let width: CGFloat
    var space: UUID? = nil
    /// The plate was asking where to go (EmptyPlate) a moment ago.
    var fromAsking = false
    /// What shows through it is blurred (PlateGround).
    var frosted = false
    @ObservedObject private var card = SiteControlsState.shared
    @Environment(\.tone) private var tone
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var hovering = false
    @State private var ticked = false
    @State private var untick: DispatchWorkItem?
    /// The address has slid in from where the question was.
    @State private var arrived = false
    @ObservedObject private var boostEditor = BoostEditor.shared
    /// Pins a window of the extension's own stands under (ExtensionWindowFrame).
    @ObservedObject private var hung = ExtensionWindowFrame.Hung.shared

    /// The plate's height at the column's density (Density), with the
    /// pins' corner under it (SideBar.corner).
    static var height: CGFloat { Density.current.plate }
    static var corner: CGFloat { SideBar.corner(height) }
    /// From the plate's edge to its doors, and their corner, concentric.
    static let air: CGFloat = 4
    static var door: CGFloat { height - 2 * air }
    static var inner: CGFloat { corner - air }
    /// Under the plate, before the pins.
    static var below: CGFloat { Density.current.plateBelow }
    /// The plate rises into the lights' band until the header's doors are
    /// as far above it as the pins are below.
    static var lift: CGFloat { (Metrics.strip - Door.Size.header.side) / 2 - below }
    /// What the column gives the plate, under the lights' band.
    static var block: CGFloat { height + below - lift }
    /// The doors' glyphs, as large as Arc draws its own in a door this size.
    static let glyph: CGFloat = 13
    /// How long the fade is at the end of a name too long for the plate.
    static let fade: CGFloat = 20

    static func pinsHeight(in browser: Browser) -> CGFloat {
        pinsHeight(in: browser, space: browser.spaceID, tab: browser.active ?? SpacePager.shared.keptPlate(in: browser))
    }

    static func pinsHeight(in browser: Browser, space: UUID?, tab: Tab?) -> CGFloat {
        extensionPlate(in: browser, space: space, tab: tab).extensionHeight
    }

    static func extensionPlate(in browser: Browser, space: UUID?, tab: Tab?, shown: Bool = true) -> SpacePlateRouting.Plate {
        guard shown, let tab, !tab.isBlank else { return .init(shown: shown) }
        // Measuring a parked space must not start its extensions.
        let signIn = Extensions.signIn(of: space ?? browser.spaceID)
        let ids: [String]
        if tab.engineKind == .chromium {
            ids = ChromiumColumn.shared.pinnedIDs(for: tab)
        } else if let loaded = Extensions.all.first(where: { $0.signIn == signIn }) {
            ids = loaded.buttons.filter(\.pinned).map(\.id)
        } else {
            ids = (Extensions.unread(signIn) ?? []).filter { $0.enabled && $0.pinned == true }.map(\.id)
        }
        let height = SideExtensionLayout(width: browser.prefs.sideWidth,
                                   count: ids.count,
                                   door: door, margin: SideBar.margin,
                                   columns: SideBar.pinColumns(ids.count, width: browser.prefs.sideWidth), gap: SideBar.pinGap).height
        return .init(shown: shown, extensionHeight: height, extensions: ids)
    }

    var body: some View {
        let facts = SiteFacts(tab: tab)
        let site = facts.site
        let pinned = tab.engineKind == .chromium ? column.buttons(for: tab) : extensions.buttons.filter(\.pinned)
        let layout = SideExtensionLayout(width: width, count: pinned.count, door: Self.door, margin: SideBar.margin,
                                         columns: SideBar.pinColumns(pinned.count, width: width), gap: SideBar.pinGap)
        // A pin's popup up keeps the plate as it is under the pointer: the
        // popup hangs from the pin, and the pointer going down into the
        // popup took the pin away, and the popup with it, before a password
        // could be typed. An unpinned one's hangs from the sliders, which
        // went the same way.
        let nativePopupID = nativePopup.shownExtension(for: tab)
        let popupID = tab.engineKind == .chromium ? nativePopupID : ExtensionPopup.shared.extensionID
        let fromDoor = tab.engineKind == .chromium ? nativePopup.shownFromDoor(for: tab) : ExtensionPopup.shared.fromDoor
        let popped: Bool = {
            if tab.engineKind == .chromium { return nativePopupID != nil }
            guard ExtensionPopup.shared.isShown else { return false }
            if fromDoor { return true }
            guard let id = ExtensionPopup.shared.extensionID else { return false }
            return pinned.contains { $0.id == id }
        }()
        // A window of an extension's own under its pin keeps the pins
        // in, the one it stands under lit (PlatePin).
        let near = near || popped || pinned.contains { hung.ids.contains($0.id) }
        // Only with the pointer in the column, as the link and the sliders:
        // a count or "!" kept one at rest, and it stood where it does in the
        // row, before the link and sliders faded out after it, in the middle
        // of the plate (an extension asking to sign in). Its count is on it
        // when the row comes in.
        let shownPins = near && !layout.separate ? pinned : []
        let paused = facts.isSite && browser.prefs.shielded && shield.isPaused(on: site)
        let camera = tab.camera == .active, microphone = tab.microphone == .active

        // Asking, the glass in front and the words after it; a site came,
        // the glass slides out past the edge and the address takes its place.
        let asking = tab.isBlank || (fromAsking && !arrived)

        // The link and the sliders fade in about as long as Arc's take; the
        // sliders stay with their panel up, a dot or a call to show.
        let up = near || hovering || ticked || card.openFor == tab.id || boostEditor.owns(tab)
        let blocker = paused && up
        let live: String? = camera ? "video" : microphone ? "mic" : nil
        // A window kept back: "Window blocked" where the link stands (WindowChip).
        let chip = facts.isSite && !tab.windows.blocked.isEmpty
        let link = facts.isSite && up && !chip
        let sliders = up || extensions.dotted || live != nil
        let doors = (blocker ? 1 : 0) + shownPins.count + (link ? 1 : 0) + (sliders ? 1 : 0)
        // What the doors cover of the site's end, the site fading out under it.
        let cover = chip ? WindowChip.cover(after: (blocker ? 1 : 0) + shownPins.count)
            : doors == 0 ? 0 : CGFloat(doors) * (Self.door + 2) - 2 + Self.air

        // The site's own inset is under the doors' cover too.
        let plate = name(cut: max(0, cover - 10))
            .padding(.leading, asking ? PlateGlass.lead : 10)
            .padding(.trailing, 10) // design: the site's own inset, the glass only ever on its left
            .frame(maxWidth: .infinity, alignment: .leading)
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: cover == 0 ? 0 : Self.fade)
                    Color.clear.frame(width: cover)
                }
            }
            .overlay(alignment: .trailing) {
                HStack(spacing: 2) {
                    if blocker {
                        PlateDoor(symbol: "xmark.shield", tip: "Ads and trackers aren't blocked here") {
                            ExtensionPanel.shared.toggle(tab: tab, page: .main, from: nil)
                        }
                    }
                    ForEach(shownPins) { button in
                        PlatePin(button: button, lit: popped && !fromDoor && popupID == button.id,
                                 native: tab.engineKind == .chromium ? tab : nil) {
                            press(button.id)
                        }
                        .transition(.opacity)
                    }
                    if chip {
                        WindowChip(browser: browser, tab: tab)
                    }
                    if facts.isSite && !chip {
                        PlateDoor(tip: "Copy URL", shortcut: "Copy URL", tint: ticked ? Palette.ink : nil) {
                            browser.copyAddress(door: true)
                        } glyph: {
                            CopyMark(ticked: ticked, side: (Self.glyph * Glyphs.scale).rounded())
                        }
                        .opacity(link ? 1 : 0)
                        .allowsHitTesting(link)
                    }
                    SiteControlsDoor(browser: browser, tab: tab, live: live, side: Self.door, corner: Self.inner, glyph: Self.glyph + 1)
                        .opacity(sliders ? 1 : 0)
                        .allowsHitTesting(sliders)
                }
                .padding(.trailing, Self.air)
            }
        .frame(height: Self.height)
        .overlay(PlateGlass(shown: asking))
        .background(PlateGround(hovering: hovering, frosted: frosted))
        .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .onHover { hovering = $0 }
        .modifier(SlidePointed(hovering: $hovering))
        .animation(still ? nil : PlateGlass.morph, value: asking)
        .onAppear {
            guard fromAsking else { return }
            // A turn later, so the plate is drawn asking first.
            DispatchQueue.main.async { arrived = true }
        }
        .animation(Motion.quick, value: near)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: card.openFor)
        .animation(Motion.quick, value: ticked)
        .onChange(of: browser.copies) { _, _ in tick() }
        .onChange(of: tab.id) { _, _ in
            untick?.cancel()
            ticked = false
        }

        VStack(spacing: 0) {
            plate
            if layout.separate, !tab.isBlank {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.cell), spacing: layout.gap), count: layout.columns),
                          spacing: layout.gap) {
                    ForEach(pinned) { button in
                        PlatePin(button: button, lit: popped && !fromDoor && popupID == button.id,
                                 width: layout.cell, plated: true, native: tab.engineKind == .chromium ? tab : nil) {
                            press(button.id)
                        }
                        .modifier(PinnedOrder(button: button, extensions: extensions))
                    }
                }
                .padding(.top, layout.gap)
                .frame(height: layout.height, alignment: .top)
            }
        }
    }

    private func press(_ id: String) {
        if tab.engineKind == .chromium { column.press(id, tab: tab) } else { extensions.press(id) }
    }

    /// The site, ⌘L when pressed. A copy leaves it where it is: the tick
    /// says one from the link, the corner one from the key. Its address
    /// tip only over the words the doors leave: the site runs on under
    /// them, and the gaps between the doors brought it up while the
    /// pointer went from one door to the next.
    private func name(cut: CGFloat) -> some View {
        Button { browser.edit() } label: {
            let words = Group {
                if tab.isBlank {
                    Text("Search or type a URL").foregroundStyle(Palette.muted(on: tone))
                } else {
                    AddressWords.text(tab: tab, tone: tone)
                }
            }
            .sidebarFont(size: 12.5)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            // As Arc writes it: always from its start, and a name too long
            // for the room fades out at its end rather than giving up its
            // front to an ellipsis. One that fits isn't faded at all.
            ViewThatFits(in: .horizontal) {
                words
                words
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .mask {
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: Self.fade)
                        }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .pointerTip(tab.address?.absoluteString ?? "", cut: cut)
        .steadyMenu(actions: true) { AddressMenu(browser: browser, tab: tab) }
    }

    /// The tick for about a second, as long as Arc keeps its; CopyMark
    /// times the turn each way.
    private func tick() {
        untick?.cancel()
        ticked = true
        let work = DispatchWorkItem { ticked = false }
        untick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CopyMark.held, execute: work)
    }
}

/// The plate as a space's page draws it while the spaces slide to or from
/// Mail (PagedSpace): the address on its ground, as SidePlate stands with
/// the pointer away, no doors. Only looked at.
struct StillPlate: View {
    let tab: Tab?
    @Environment(\.tone) private var tone

    var body: some View {
        let asking = tab?.isBlank ?? true
        Group {
            if let tab, !asking {
                AddressWords.text(tab: tab, tone: tone)
            } else {
                Text("Search or type a URL").foregroundStyle(Palette.muted(on: tone))
            }
        }
        .sidebarFont(size: 12.5)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        // No wider than the plate whatever the address: with no least
        // width the frame took the whole address's, and the page it is on
        // with it, every row of the page as wide and none of their names
        // faded until the column's own came back as the row landed.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: SidePlate.fade)
            }
        }
        .padding(.leading, asking ? PlateGlass.lead : 10)
        .padding(.trailing, 10) // design: the site's own inset, as SidePlate's
        .frame(height: SidePlate.height)
        .overlay(PlateGlass(shown: asking))
        .background(PlateGround(hovering: false, frosted: false))
        .clipShape(RoundedRectangle(cornerRadius: SidePlate.corner, style: .continuous))
    }
}

/// The plate on a space's page as it slides in (PagedSpace). Its extension
/// grid stays visible with the pointer outside too, just as in the live
/// column; only the address's inline doors depend on the pointer.
struct PagedPlate: View {
    let browser: Browser
    let tab: Tab?
    let width: CGFloat
    var space: UUID? = nil
    @Environment(\.slidePointer) private var pointer

    var body: some View {
        if let pointer, let tab {
            Pointed(browser: browser, tab: tab, width: width, space: space, pointer: pointer)
        } else {
            still
        }
    }

    /// Draw the grid itself wherever the live column will show one.
    @ViewBuilder
    private var still: some View {
        if let tab, !tab.isBlank {
            SidePlate(browser: browser, tab: tab, near: false, width: width, space: space)
        } else {
            StillPlate(tab: tab)
        }
    }

    private struct Pointed: View {
        let browser: Browser
        let tab: Tab
        let width: CGFloat
        let space: UUID?
        @ObservedObject var pointer: SlidePointer

        var body: some View {
            if !tab.isBlank {
                SidePlate(browser: browser, tab: tab, near: pointer.near, width: width, space: space)
            } else {
                StillPlate(tab: tab)
            }
        }
    }
}

/// A door inside the plate: the plate's height less its air, concentric.
/// The column's plate with no tab in front: where the address would be,
/// asking where to go, ⌘T's field when pressed. The pins and rows under it
/// stay where they were.
struct EmptyPlate: View {
    @ObservedObject var browser: Browser
    var frosted = false
    @Environment(\.tone) private var tone
    @State private var hovering = false

    var body: some View {
        Button { browser.newTab() } label: {
            Text("Search or type a URL")
                .foregroundStyle(Palette.muted(on: tone))
                .sidebarFont(size: 12.5)
                .lineLimit(1)
                .padding(.leading, PlateGlass.lead)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .frame(height: SidePlate.height)
        .overlay(PlateGlass(shown: true))
        .background(PlateGround(hovering: hovering, frosted: frosted))
        .contentShape(RoundedRectangle(cornerRadius: SidePlate.corner, style: .continuous))
        .onHover { hovering = $0 }
    }
}

/// The plate's ground: the column's wash, lighter at rest than under the
/// pointer. Frosted, over drawings or glass, what shows through it is
/// blurred first (PlateBlur), so the address reads over the drawings'
/// lines and a window's words behind it.
private struct PlateGround: View {
    let hovering: Bool
    let frosted: Bool
    @Environment(\.tone) private var tone

    var body: some View {
        RoundedRectangle(cornerRadius: SidePlate.corner, style: .continuous)
            .fill(Palette.resting(on: tone, hovering: hovering))
            .background {
                if frosted { PlateBlur(corner: SidePlate.corner) }
            }
    }
}

/// The glass in front of a plate that asks where to go. When a site comes
/// it slides out past the plate's left edge and fades, as Arc's does, and
/// the address moves into its place; the plate clips it.
struct PlateGlass: View {
    let shown: Bool
    @Environment(\.tone) private var tone

    /// From the plate's edge to the glass.
    static let edge: CGFloat = 9
    static var side: CGFloat { (SidePlate.glyph * Glyphs.scale).rounded() }
    /// Where the words start with the glass in front of them.
    static var lead: CGFloat { edge + side + 6 }
    /// Arc's own: about 120 ms, stopping short.
    static let morph = Animation.easeOut(duration: 0.12)

    var body: some View {
        Symbol("magnifyingglass", size: SidePlate.glyph, weight: .medium)
            .foregroundStyle(Palette.muted(on: tone))
            .frame(width: Self.side, height: Self.side)
            .offset(x: shown ? 0 : -(Self.edge + Self.side))
            .opacity(shown ? 1 : 0)
            .padding(.leading, Self.edge)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: SidePlate.corner, style: .continuous))
            .allowsHitTesting(false)
    }
}

/// A pinned extension's button in the plate: its own icon, on the same
/// square as the plate's doors under the pointer, and the deeper one while
/// its popup hangs from it, as the sliders stand with their panel up.
@available(macOS 15.4, *)
/// A pinned extension's door: the plate's, and the band's over the page
/// (AddressBar), each at its own size.
struct PlatePin: View {
    let button: Extensions.Button
    /// Its popup is up from it.
    let lit: Bool
    var side: CGFloat = SidePlate.door
    var corner: CGFloat = SidePlate.inner
    var width: CGFloat? = nil
    var plated = false
    /// A Chromium tab's native extension: its own right-click lines.
    var native: Tab? = nil
    let act: () -> Void
    @Environment(\.tone) private var tone
    @State private var hovering = false
    /// A window of its own stands under it (ExtensionWindowFrame): lit too.
    @ObservedObject private var hung = ExtensionWindowFrame.Hung.shared

    var body: some View {
        let lit = self.lit || hung.ids.contains(button.id)
        Button(action: act) {
            ExtensionIcon(button: button, size: 14)
                .frame(width: 18, height: 18)
                .frame(width: width ?? side, height: side)
                .background(RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(lit ? Palette.wash(on: tone) : hovering ? Palette.hover(on: tone) : plated ? Palette.wash(on: tone) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(Door.Give())
        .focusable(false)
        .onHover {
            hovering = $0
            // Its menu's own rows, read before a right click asks for them.
            if $0, let native { ChromiumActionMenu.shared.refresh(button.id, tab: native) }
        }
        .keyTip(button.label, keys: button.keys)
        // Right-clicked, what its tile in the panel offers (ExtensionActions).
        .steadyMenu(actions: true) {
            if let native { ChromiumPinActions(id: button.id, name: button.name, tab: native) }
            else { ExtensionActions(id: button.id, name: button.name, extensions: Extensions.here) }
        }
        .background {
            if let native { ChromiumPopupAnchor(id: button.id, tab: native) }
            else { ExtensionAnchor(id: button.id) }
        }
    }
}

private struct PlateDoor<Glyph: View>: View {
    let tip: String
    var shortcut: String?
    var tint: Color?
    let act: () -> Void
    @ViewBuilder let glyph: Glyph
    @Environment(\.tone) private var tone
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            glyph
                .foregroundStyle(tint ?? (hovering ? Palette.ink : Palette.muted(on: tone)))
                .frame(width: SidePlate.door, height: SidePlate.door)
                .background(RoundedRectangle(cornerRadius: SidePlate.inner, style: .continuous)
                    .fill(hovering ? Palette.hover(on: tone) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(Door.Give())
        .focusable(false)
        .onHover { hovering = $0 }
        .keyTip(tip, shortcut: shortcut)
    }
}

extension PlateDoor where Glyph == Symbol {
    init(symbol: String, tip: String, shortcut: String? = nil, tint: Color? = nil, act: @escaping () -> Void) {
        self.init(tip: tip, shortcut: shortcut, tint: tint, act: act) { Symbol(symbol, size: SidePlate.glyph, weight: .medium) }
    }
}

/// The site, as the band and the plate both write it (AddressBar).
enum AddressWords {
    /// The part that owns it in the ink and whatever sits in front of it in
    /// the gray; for a page that has no site, what the page is called.
    @MainActor
    static func text(tab: Tab, tone: Tone?) -> Text {
        let ink = Palette.ink
        let muted = Palette.muted(on: tone)
        guard let url = tab.address else { return Text("") }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https", let raw = url.host(), !raw.isEmpty else {
            // The app's own pages, a file, an extension's page: by name.
            let name = tab.title.isEmpty ? (scheme == "file" ? url.lastPathComponent : Address.shown(url)) : tab.title
            // An agent's published page: its title, and its version once it has another.
            if scheme == ArtifactPages.scheme, let seq = url.host().flatMap({ ArtifactPages.shared.entry($0.lowercased())?.seq }), seq > 1 {
                return Text(name).foregroundStyle(ink) + Text(" \u{00B7} Version \(seq)").foregroundStyle(muted)
            }
            return Text(name).foregroundStyle(ink)
        }
        let host = IDN.shown(raw.lowercased().hasPrefix("www.") ? String(raw.dropFirst(4)) : raw)
        // A local page not in Developer Mode: the server and its port, and
        // plain http is nothing to warn about there either.
        if tab.isLocal && !tab.isDev {
            return Text(host).foregroundStyle(ink) + Text(verbatim: url.port.map { ":" + String($0) } ?? "").foregroundStyle(muted)
        }
        // A page being made on this Mac: the whole address, as Arc writes
        // it. The server and its port in the ink, what says which page of
        // the project this is after them, the scheme let down in front.
        // Plain http here is nothing to warn about.
        if tab.isDev {
            let port = url.port.map { ":\($0)" } ?? ""
            var rest = url.path(percentEncoded: false)
            if let query = url.query(percentEncoded: false) { rest += "?" + query }
            if let fragment = url.fragment(percentEncoded: false) { rest += "#" + fragment }
            if rest == "/" { rest = "" }
            return Text(scheme + "://").foregroundStyle(muted)
                + Text(raw.lowercased() + port).foregroundStyle(ink)
                + Text(rest).foregroundStyle(ink.opacity(0.62))
        }
        let owner = Browser.site(host)
        let front = host.count > owner.count && host.lowercased().hasSuffix(owner) ? String(host.dropLast(owner.count)) : ""
        let site = Text(front).foregroundStyle(muted) + Text(host.dropFirst(front.count)).foregroundStyle(ink)
        // Nothing to say for https: only the exception is written down.
        return scheme == "http" ? Text("Not secure  ").foregroundStyle(muted) + site : site
    }
}

/// The address's own menu, on the column's plate and on the bar over the
/// page: copy, share and capture the page, choose how much of the URL is
/// shown, and move the address between the column and the top of the page.
struct AddressMenu: View {
    let browser: Browser
    let tab: Tab
    @ObservedObject private var prefs: Preferences

    init(browser: Browser, tab: Tab) {
        self.browser = browser
        self.tab = tab
        self.prefs = browser.prefs
    }

    var body: some View {
        let site = tab.address.map { !$0.isFileURL && $0.scheme?.lowercased() != DiaryPage.scheme } ?? false
        if site {
            Button("Copy URL", mark: "link") { browser.focus(tab); browser.copyAddress() }
            if let url = tab.address {
                ShareLink(item: Diary.shareable(url)) {
                    Label { Text("Share") } icon: { Image(nsImage: MenuMark.image("yab.share")) }
                }
            }
        }
        if !tab.isBlank {
            Button("Capture…", mark: "yab.element") { browser.focus(tab); browser.capture.start() }
            Button("Capture Full Page", mark: "yab.page") {
                browser.focus(tab)
                browser.capture.start()
                browser.capture.take(.whole)
            }
        }
        if tab.paper.pdf, tab.paper.desk == nil {
            Button("Fill & Sign", mark: "signature") { browser.fillSign(tab) }
        }
        Divider()
        Toggle("Always Show Full URL", isOn: $prefs.fullURL)
        // With the tabs across the top the bar is the only place the
        // address has, so it stays. A hidden bar can be brought back from
        // the address in the sidebar, with the same URL format as before.
        if prefs.sidebar {
            Button(prefs.addressBar ? "Hide Address Bar" : "Show as Address Bar",
                   mark: prefs.addressBar ? "yab.bar.hide" : "yab.bar.show") {
                prefs.addressBar.toggle()
            }
        }
    }
}

/// The address written out whole, as Arc's bar writes it: no scheme and
/// no www, the host in the ink and what comes after it let down.
enum FullAddress {
    @MainActor
    static func text(_ url: URL, tone: Tone?) -> Text {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https", let raw = url.host(), !raw.isEmpty else {
            return Text(url.absoluteString).foregroundStyle(Palette.ink)
        }
        let host = IDN.shown(raw.lowercased().hasPrefix("www.") ? String(raw.dropFirst(4)) : raw)
        var rest = url.path(percentEncoded: false)
        if let query = url.query(percentEncoded: false) { rest += "?" + query }
        if let fragment = url.fragment(percentEncoded: false) { rest += "#" + fragment }
        if rest == "/" { rest = "" }
        let port = url.port.map { ":\($0)" } ?? ""
        let words = Text(host + port).foregroundStyle(Palette.ink) + Text(rest).foregroundStyle(Palette.muted(on: tone))
        return scheme == "http" ? Text("Not secure  ").foregroundStyle(Palette.muted(on: tone)) + words : words
    }
}

/// The panel, drawn off screen, for the bench, which can't keep a popover
/// open in a browser that isn't in front.
@MainActor
func siteControlsPicture(_ browser: Browser, page: SitePage, hidden: Bool = false, dark: Bool? = nil) -> NSBitmapImageRep? {
    guard let tab = browser.active else { return nil }
    let state = SiteControlsState()
    state.page = page
    state.hiddenOpen = hidden
    let view = SiteControlsView(browser: browser, tab: tab, prefs: browser.prefs, translation: browser.pageTranslation,
                                extensions: Extensions.of(browser), state: state)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua)! } ?? NSApp.effectiveAppearance
    window.contentView = WindowHosting.measured(host)
    host.layoutSubtreeIfNeeded()
    guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: picture)
    return picture
}
