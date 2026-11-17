import SwiftUI
import AppKit

// A window, a row of titles, and a field. Typing an address gets you a page;
// there is nothing else to learn and nothing else to press. The same binary
// is also a door for agents, see main.swift.

struct YabApp: App {
    /// The first moment of the launch the app itself sees (Startup).
    private let begun: Void = Startup.mark("main")
    /// First, before any window: a first run from outside
    /// Applications moves in and opens from there (see Arrival).
    private let settled: Void = Arrival.settle
    @StateObject private var browser = Browser()
    @StateObject private var windows = BrowserWindows.shared
    private var selected: Browser { windows.activeBrowser ?? browser }
    /// Links from other apps, and the Dock icon.
    @NSApplicationDelegateAdaptor(Links.self) private var links

    var body: some Scene {
        Window("Yab", id: "browser") {
            ContentView(browser: browser)
                .windowFloor(browser)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                FileItems(selected: selected, windows: windows)
            }
            // Grouped: a scene's commands take ten at most.
            Group {
                CommandGroup(replacing: .saveItem) {}
                CommandGroup(replacing: .printItem) {
                    PrintItems(selected: selected, windows: windows)
                }
            }
            CommandGroup(after: .pasteboard) {
                PasteStyleMenuItem()
                FindItems(selected: selected, windows: windows)
            }
            CommandGroup(replacing: .toolbar) {
                ViewItems(selected: selected, windows: windows)
            }
            CommandMenu("Tabs") {
                TabsItems(selected: selected, windows: windows)
            }
            Group {
                SpacesMenuCommands(browser: selected)
                CommandMenu("Bookmarks") {
                    BookmarksItems(selected: selected, windows: windows)
                }
            }
            CommandMenu("History") {
                HistoryItems(selected: selected, windows: windows)
            }
            // The Mac's own Window menu, Minimize and Zoom kept, rather than
            // a second menu of yab's beside it: reopening a closed window
            // (closing one is in File), and Mail. The windows themselves
            // AppKit lists, by the title each wears (BrowserWindows.retitle),
            // as the Dock does.
            CommandGroup(after: .windowSize) {
                WindowItems(selected: selected, windows: windows)
            }
            // The Yab menu's two, as one: a scene's commands take ten.
            Group {
                CommandGroup(after: .appInfo) {
                    UpdateMenu { selected }
                }
                CommandGroup(after: .appSettings) {
                    SettingsItems(selected: selected, windows: windows)
                }
            }
            CommandGroup(replacing: .help) {
                HelpItems(selected: selected, windows: windows)
            }
        }
    }
}

/// File's new and close items (YabApp). A view of its own, so that what
/// it reads of the browser in front (the tab, its address, the tabs
/// chosen) redraws these items alone: read in the scene's body, each
/// tab picked made SwiftUI rebuild the scene and push a new
/// environment into every row of the column (row 1123).
private struct FileItems: View {
    @ObservedObject var selected: Browser
    @ObservedObject var windows: BrowserWindows

    var body: some View {
        Button("New Window") { selected.newWindow() }
            .shortcut(.newWindow)
        // Arc's, under New Window (BlankWindow.swift).
        Button("Blank Window") { selected.newBlankWindow() }
            .shortcut(.blankWindow)
        Divider()
        Button("New Tab") { selected.pressNewTab() }
            .shortcut(.newTab)
        Button("New Tab in Folder") { selected.newTab(in: selected.folderHere) }
            .shortcut(.newTabInFolder)
            .disabled(selected.folderHere == nil)
        Button("New Private Window") { selected.newPrivateWindow() }
            .shortcut(.privateTab)
        Button(selected.reopensWindow ? "Reopen Closed Window" : "Reopen Closed Tab") { selected.reopen() }
            .shortcut(.reopen)
            .disabled(selected.ghosts.isEmpty && !selected.reopensWindow)
        Divider()
        Button("Open Address…") { selected.pressOpenAddress() }
            .shortcut(.openAddress)
        Button("Paste and Go") {
            // From its key, in a text field, the key is the text's
            // (PasteStyleTarget.takesPasteAndGoKey). Chosen from the menu,
            // by the pointer or by the arrows and Return, it goes.
            if let event = NSApp.currentEvent, event.type == .keyDown, Keymap.shared.matches(event, .pasteAndGo),
               PasteStyleTarget.takesPasteAndGoKey(in: NSApp.keyWindow) { return }
            selected.pasteAndGo()
        }
            .shortcut(.pasteAndGo)
        Divider()
        // Close Tab and Close Window in
        // File, in place of AppKit's own Close and Close All (see
        // .saveItem): those kept ⌘W behind Close Tab and shut the
        // whole window once Close Tab had another key. Another
        // window in front, Settings or a link's, is closed itself.
        Button(DocumentPiP.owning(NSApp.keyWindow) != nil ? "Close Window" : selected.several ? "Close \(selected.chosenCount) Tabs" : "Close Tab") {
            if DocumentPiP.closeKeyWindow() { return }
            if let key = NSApp.keyWindow, windows.browser(for: key) == nil { key.performClose(nil); return }
            selected.shut(selected.chosen)
        }
            .shortcut(.closeTab)
        Button("Close Window") {
            if !DocumentPiP.closeKeyWindow() { windows.activeWindow?.performClose(nil) }
        }
            .shortcut(.closeWindow)
    }
}

/// Print and Capture (YabApp).
private struct PrintItems: View {
    @ObservedObject var selected: Browser
    @ObservedObject var windows: BrowserWindows

    var body: some View {
        Button("Print…") { selected.printPage() }
            .shortcut(.print)
            .disabled(selected.menuBlank)
        Button("Capture…") { selected.capture.start() }
            .shortcut(.capture)
            .disabled(selected.menuBlank)
    }
}

/// Find on Page and its steps, in Edit (YabApp).
private struct FindItems: View {
    @ObservedObject var selected: Browser
    @ObservedObject var windows: BrowserWindows

    var body: some View {
        Divider()
        Button("Find on Page…") { selected.openFind() }
            .shortcut(.find)
            .disabled(selected.menuBlank)
        Button("Find Next") { selected.look(forward: true) }
            .shortcut(.findNext)
            .disabled(!selected.finding)
        Button("Find Previous") { selected.look(forward: false) }
            .shortcut(.findPrevious)
            .disabled(!selected.finding)
    }
}

/// The View menu (YabApp).
private struct ViewItems: View {
    @ObservedObject var selected: Browser
    @ObservedObject var windows: BrowserWindows

    var body: some View {
        AppearanceMenu(browser: selected)
        Divider()
        Menu("Layout") {
            Toggle("Show Tabs in Sidebar", isOn: Binding(
                get: { selected.prefs.sidebar },
                set: { _ in selected.toggleSidebar() }
            ))
            .shortcut(.sidebarTabs)
            // The column put away, or with the tabs across the top, the
            // strip (Browser.toggleStrip).
            Button(selected.columnTitle) { selected.toggleColumn() }
                .shortcut(.column)
            Toggle("Show Address Bar", isOn: Binding(
                get: { selected.prefs.addressBar },
                set: { selected.prefs.addressBar = $0 }
            ))
            .shortcut(.addressBar)
            // Settings' Address bar: Site or Full URL, when it shows.
            Toggle("Show Full URL", isOn: Binding(
                get: { selected.prefs.fullURL }, set: { selected.prefs.fullURL = $0 }
            ))
            .disabled(!selected.prefs.addressBar)
            BookmarksBarMenu(browser: selected)
        }
        Menu("Split") {
            SplitMenuCommands(browser: selected)
        }
        Divider()
        Button("Reload Page") { selected.reload() }
            .shortcut(.reload)
        Button("Reload Without Cache") { selected.hardReload() }
            .shortcut(.hardReload)
        Button("Clear Cookies and Refresh") { selected.clearCookiesAndRefresh() }
        Button("Reading Mode") { selected.toggleReader() }
            .shortcut(.reader)
        ReaderAppearanceMenu(browser: selected)
        TranslatePageMenu(browser: selected, translation: selected.pageTranslation)
        // A page that came as JSON, as text or as a tree (JSONView.swift).
        Button(selected.jsonFront?.json?.shown == .tree ? "Show JSON as Text" : "Show JSON as Tree") { selected.toggleJSON() }
            .shortcut(.jsonView)
            .disabled(selected.jsonFront == nil || selected.jsonFront?.json?.ndjson == true)
        Button("Float Video") { selected.toggleFloat() }
            .shortcut(.float)
        Divider()
        // The page's own panel: what to do with it, its extensions,
        // what this site is allowed and what was hidden on it.
        Button("Site Controls") { selected.toggleExtensions() }
            .shortcut(.extensions)
        Button("Hide Elements…") { selected.toggleHiding() }
            .shortcut(.hide)
        // Yab's buttons in this site's own rows, said with the site's
        // name, so Help's search finds it by "button" (SiteItems).
        SiteButtonsCommand(browser: selected)
        Divider()
        Button("Zoom In") { selected.zoom(by: 1.1) }
            .shortcut(.zoomIn)
        Button("Zoom Out") { selected.zoom(by: 1 / 1.1) }
            .shortcut(.zoomOut)
        Button("Actual Size") { selected.resetZoom() }
            .shortcut(.actualSize)
        Divider()
        DeveloperMenuCommands(browser: selected)
        if selected.chatOpen {
            Button("Hide Chat") { selected.hideChat() }
                .shortcut(.closeChat)
            if !selected.chatHistory, Chats.shared.chat(selected.chatID) != nil {
                Button("Move to Project\u{2026}") { ChatMoves.ask(in: selected) }
                    .shortcut(.moveToProject)
            }
        } else if AIUse.chats {
            // No agent and no chat yet: nothing for the column to show.
            Button("Show Chat") { selected.moveChat(open: true) }
                .shortcut(.closeChat)
        }
        // Developer Mode is switched where the site's other settings
        // are, ⌘E, and in ⌘K and Settings › Developers (DevMode.swift).
    }
}

/// The Tabs menu (YabApp).
private struct TabsItems: View {
    @ObservedObject var selected: Browser
    @ObservedObject var windows: BrowserWindows

    var body: some View {
        AgentCommands(browser: selected)
        Divider()
        Button("Next Tab") { selected.step(1) }
            .shortcut(.nextTab)
        Button("Previous Tab") { selected.step(-1) }
            .shortcut(.previousTab)
        NumberedTabsMenu(browser: selected)
        Button("Move Tab Left") { selected.nudge(-1) }
            .shortcut(.moveLeft)
        Button("Move Tab Right") { selected.nudge(1) }
            .shortcut(.moveRight)
        Divider()
        if selected.several {
            let chosen = selected.chosen
            let n = chosen.count
            let loose = chosen.filter { $0.pin == nil && !$0.isBlank }.count
            if loose > 0 {
                Button("Pin \(loose) Tabs") { selected.pin(chosen) }
                    .shortcut(.pin)
            } else {
                Button("Unpin \(n) Tabs") { selected.unpin(chosen) }
                    .shortcut(.pin)
            }
            Button("Duplicate \(n) Tabs") { selected.duplicate(chosen) }
                .shortcut(.duplicate)
            Button("Copy \(n) URLs") { selected.copyAddresses(chosen) }
                .shortcut(.copyAddress)
            Button("Copy \(n) Markdown Links") { selected.copyMarkdownLink(chosen) }
                .shortcut(.copyMarkdownLink)
        } else {
            if let tab = selected.active {
                if tab.pin == nil {
                    Button("Pin Tab") { selected.pin(tab) }
                        .shortcut(.pin)
                        .disabled(selected.menuBlank)
                    Button("Rename Tab…") { selected.beginTabEdit(tab) }
                        .shortcut(.rename)
                        .disabled(selected.menuBlank)
                } else {
                    // A pin's letter is changed from its own menu,
                    // with the rest of its mark.
                    Button("Unpin Tab") { selected.unpin(tab) }
                        .shortcut(.pin)
                }
            }
            Button("Duplicate Tab") { selected.duplicate() }
                .shortcut(.duplicate)
                .disabled(selected.menuBlank)
            if let tab = selected.active {
                Divider()
                Button("Move Tab to New Window") { windows.moveToNewWindow(tab, from: selected) }
                    .shortcut(.moveToWindow)
                    .disabled(tab.shy || tab.onCall || tab.everywhere != nil || selected.partner(of: tab) != nil)
                let otherWindows = windows.otherWindows(than: selected)
                if !otherWindows.isEmpty {
                    Menu("Move Tab to Window") {
                        ForEach(Array(otherWindows.enumerated()), id: \.offset) { item in
                            Button(item.element.title) { _ = windows.move(tab, from: selected, to: item.element.browser) }
                                .disabled(item.element.browser.spaceID != selected.spaceID || tab.shy || tab.onCall || tab.everywhere != nil || selected.partner(of: tab) != nil)
                        }
                    }
                }
                Button("Open Copy in New Window") {
                    guard let url = tab.address else { return }
                    windows.newWindow(from: selected).arrive(url)
                }
                .disabled(selected.menuBlank || tab.shy)
            }
            Button("Copy URL") { selected.copyAddress() }
                .shortcut(.copyAddress)
                .disabled(selected.menuBlank)
            Button("Copy Markdown Link") { selected.copyMarkdownLink() }
                .shortcut(.copyMarkdownLink)
                .disabled(selected.menuBlank)
            if selected.menuShare != nil {
                Button("Share Page…") { selected.sharePage() }
                    .shortcut(.sharePage)
            }
        }
        // A link looked at with ⇧-click (LinkPeek.swift), only while
        // one is open: they do nothing otherwise. In the menu so App
        // Shortcuts can give them keys of their own; Escape isn't
        // an item's, or pages would never hear it (MenuKey leaves a
        // key with nothing held out of the menu).
        if selected.peeking != nil {
            Divider()
            Button("Open Peek as Tab") { selected.keepPeek() }
                .shortcut(.peekTab)
            Button("Open Peek in Split View") { selected.splitPeek() }
                .shortcut(.peekSplit)
            Button("Close Peek") { selected.closePeek() }
                .shortcut(.peekClose)
        }
        Divider()
        Button("Close Other Tabs") { selected.closeOthers(but: selected.chosen) }
            .shortcut(.closeOthers)
            .disabled(selected.tabs.count <= selected.chosenCount)
        if !selected.chosen.isEmpty, selected.chosen.allSatisfy({ $0.pin == nil && !$0.kept }) {
            Button(Shortcut.titles(sidebar: selected.prefs.sidebar)[.closeBefore]!) { selected.closeBefore() }
                .shortcut(.closeBefore)
                .disabled(selected.sideCloseTargets(selected.chosen, before: true).isEmpty)
            Button(Shortcut.titles(sidebar: selected.prefs.sidebar)[.closeAfter]!) { selected.closeAfter() }
                .shortcut(.closeAfter)
                .disabled(selected.sideCloseTargets(selected.chosen, before: false).isEmpty)
        }
        Button("Pick All Tabs") { selected.pickAll() }
            .shortcut(.pickAll)
            .disabled(selected.tabs.count < 2)
        Button(selected.chosen.allSatisfy(\.kept) ? "Don’t Keep Tab" : "Keep Tab") { selected.toggleKeepTabs() }
            .shortcut(.keepTab)
            .disabled(!selected.menuKeepable)
        Button("New Folder with Tabs") { selected.newFolder(picked: selected.chosen) }
            .shortcut(.folderWithTabs)
            .disabled(!selected.menuKeepable)
        MuteCommand(browser: selected, tab: selected.active)
        Divider()
        CallCommands(browser: selected, calls: selected.calls)
    }
}

/// The Bookmarks menu's own two (YabApp).
private struct BookmarksItems: View {
    @ObservedObject var selected: Browser
    @ObservedObject var windows: BrowserWindows

    var body: some View {
        Button(selected.several ? "Add \(selected.chosenCount) Tabs to a Folder" : "Add This Page") {
            selected.several ? selected.keep(selected.chosen) : selected.bookmarkCurrent()
        }
            .shortcut(.bookmark)
            .disabled(selected.menuBlank)
        Button("Show Bookmarks") { selected.showBookmarks() }
            .shortcut(.bookmarks)
        // The bookmarks themselves follow, put in by AppKit as the
        // menu opens (BookmarkMenu.swift).
    }
}

/// The History menu (YabApp).
private struct HistoryItems: View {
    @ObservedObject var selected: Browser
    @ObservedObject var windows: BrowserWindows

    var body: some View {
        // The way back and forth, where Safari and Chrome keep it,
        // as their keys: the page just appears.
        Button("Back") { selected.back(byKey: true) }
            .shortcut(.back)
            .disabled(!selected.menuBack)
        Button("Forward") { selected.forward(byKey: true) }
            .shortcut(.forward)
            .disabled(!selected.menuForward)
        Divider()
        RecentlyVisited(history: selected.history, browser: selected)
        if !selected.ghosts.isEmpty {
            Section("Recently Closed") {
                ForEach(selected.recentlyClosed.prefix(10)) { line in
                    switch line {
                    case .tab(let ghost):
                        Button {
                            selected.reopen(ghost)
                        } label: {
                            MenuLine(title: ghost.label, url: ghost.url)
                        }
                    case .folder(let nest, let group):
                        // The folder back with its tabs, as ⌘⇧T
                        // brings the batch.
                        Button {
                            selected.reopen(from: group[0])
                        } label: {
                            Label("\(nest.name.isEmpty ? "Folder" : nest.name) · \(group.count) tabs", systemImage: "folder")
                        }
                    }
                }
            }
        }
        Divider()
        // The keys go into the box's places, which hold all of it.
        Button("Search History") { selected.openPlace(.history) }
            .shortcut(.history)
        Button("Search Downloads") { selected.openPlace(.downloads) }
            .shortcut(.downloads)
        // Clearing it all is in Settings › Privacy, which asks
        // first: from here it went in one click, page memory and
        // agents' finds with it.
    }
}

/// Reopen Closed Window and Mail, in Window (YabApp).
private struct WindowItems: View {
    @ObservedObject var selected: Browser
    @ObservedObject var windows: BrowserWindows

    var body: some View {
        Divider()
        Button("Reopen Closed Window") { windows.reopenClosedWindow() }
            .disabled(!windows.canReopen)
        if selected.prefs.usesMail {
            Divider()
            // Mail's space and back, once an account is in (MailSpace).
            Button(selected.inMail ? "Back to Your Tabs" : "Mail") { selected.toggleMail() }
                .shortcut(.mail)
                .disabled(!MailCenter.shared.connected && !selected.inMail)
        }
    }
}

/// Settings and the rest under it, in the Yab menu (YabApp).
private struct SettingsItems: View {
    @ObservedObject var selected: Browser
    @ObservedObject var windows: BrowserWindows

    var body: some View {
        Button("Settings…") { selected.tuning = true }
            .shortcut(.settings)
        Divider()
        Button("Make Yab Default Browser…") {
            Links.becomeDefault { worked in
                if !worked { selected.announce("macOS kept your old browser", mark: "safari") }
            }
        }
        .disabled(Links.isDefault)
        Button("Import from Another Browser…") { SettingsWindow.shared.show(.bringIn, for: selected) }
        Button("Invite a Friend…") { SettingsWindow.shared.show(.inviteFriends, for: selected) }
        // Passwords and Autofill are places in the field, ⌘K and
        // Settings; ⌥⌘L still opens Passwords.
    }
}

/// The Help menu (YabApp).
private struct HelpItems: View {
    @ObservedObject var selected: Browser
    @ObservedObject var windows: BrowserWindows

    var body: some View {
        Button("Yab Manual") { Command.manual.run(in: selected) }
        Button("Welcome…") {
            selected.welcoming = true
            LaunchArrival.shared.replay(selected)
        }
        Button("Send Feedback…") { Links.writeFeedback() }
            .shortcut(.sendFeedback)
        Divider()
        Button("Copy Diagnostics") { selected.copyMenuDiagnostics() }
    }
}


/// A page, as a line in a menu: its icon if one is known, and its name.
private struct MenuLine: View {
    let title: String
    let url: URL

    var body: some View {
        if let host = url.host()?.lowercased(),
           let icon = Favicons.shared.cached(host) {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: MenuLine.small(icon))
            }
        } else {
            Text(title)
        }
    }

    /// The cached icon is sixty-four points across; a menu wants sixteen.
    private static func small(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// Whatever is drawn in a tab's color, kept up with it as the page changes
/// its mind, a site that turns dark after it loads, a theme-color that
/// arrives late, and eased from one tab's color to the next.
struct Toned<Content: View>: View {
    @ObservedObject var tab: Tab
    /// Worn as a backdrop, with the live tab a chip lifted off it.
    var lifted = false
    @ViewBuilder let content: (Tone?) -> Content

    var body: some View {
        let tone = tab.tone.map { Tone($0, lifted: lifted) }
        content(tone).animation(Motion.quick, value: tone)
    }
}

/// The address bar while the bookmarks come or go: laid out where it ends,
/// drawn where the row as drawn would put it. Only `up` is animated; the
/// layout's own state, `shown`, changes at once, so the difference goes
/// from a whole shift to none on the animation's curve.
private struct ShelfCarry: ViewModifier, Animatable {
    var up: CGFloat
    let shown: CGFloat
    let shift: CGFloat

    var animatableData: CGFloat {
        get { up }
        set { up = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(y: (up - shown) * shift)
    }
}

/// The address bar's clip: nothing up or down while it is shown, so the bar
/// carried where it was (`ShelfCarry`), a whole row up as ⌘S brings the
/// strip back, and the seam of its color under it are drawn whole; cut
/// at a row's height they were gone until the bar had nearly landed, the
/// paper showing where it should have been. All of it while it is built
/// ahead out of sight, at no height (SplitPreview.warm).
private struct BandClip: Shape {
    let open: Bool

    func path(in rect: CGRect) -> Path {
        Path(open ? rect.insetBy(dx: 0, dy: -Self.reach) : rect)
    }

    /// Past the bar's own height, up and down: the most it is ever carried,
    /// the strip's row and the bookmarks' together, and its seam under it.
    private static let reach = 2 * (Metrics.row + BookmarkBar.height)
}

/// The strip drawn as far down as `down` has it: 1 in its place, 0 gone up
/// past the window's top edge, `travel` points up. Only `down` is animated,
/// so the strip moves on whatever curve the change that moved it asked for,
/// ⌘S's or the edge's.
private struct StripPlace: ViewModifier, Animatable {
    var down: CGFloat
    let travel: CGFloat

    var animatableData: CGFloat {
        get { down }
        set { down = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(y: -(1 - down) * travel)
    }
}

/// The page column down by `ContentView.headSink` while the band with the
/// lights is out. It watches the band's own object (HeadPeek), so the band
/// coming out draws this again, not the window. Never stepped by SwiftUI:
/// the page and its paper are slid there by Core Animation first, and the
/// column is laid out there once they have landed (Browser.moveHead,
/// Reshape.slide).
private struct HeadSunk: ViewModifier {
    @ObservedObject var peek: HeadPeek
    /// There is a band: the column on the right, in a window.
    let band: Bool
    let laid: Bool
    let shelf: CGFloat

    func body(content: Content) -> some View {
        let reach = band ? ContentView.headSink(out: true, laid: laid, shelf: shelf) : 0
        let sink = peek.sunk ? reach : 0
        content
            .offset(y: sink)
            .transaction(value: sink) { $0.animation = nil }
            .onChange(of: reach, initial: true) { peek.sink = reach }
    }
}

/// The band's lights and title shown once its room is made, and clickable
/// while it is out (HeadPeek).
private struct HeadShown: ViewModifier {
    @ObservedObject var peek: HeadPeek

    func body(content: Content) -> some View {
        content
            .opacity(peek.shown ? 1 : 0)
            .allowsHitTesting(peek.out)
    }
}

/// The strip as ⌘S and the window's top edge have it: in its place, put
/// away up past the edge, or out over the page for a while. It watches the
/// strip's own peek (StripPeek), which the window's view doesn't, so the
/// edge bringing it out or letting it go draws the strip again, not the
/// whole window.
private struct StripPlaced<Content: View>: View {
    @ObservedObject var peek: StripPeek
    /// Put away by ⌘S (`prefs.stripShut`).
    let shut: Bool
    /// ⌘S moves it, drawn as far down as `down` (Browser.stripDown).
    let moving: Bool
    let down: CGFloat
    /// AppKit positions and clips its fullscreen accessory as one surface.
    var nativeFullscreen = false
    /// The strip, lifted off the page or flat (StripPeek.card).
    @ViewBuilder let content: (_ lifted: Bool) -> Content

    /// In sight: in its place, or out over the page, the edge having
    /// brought it. Put away, it stays out of sight while ⇧⌘S takes the tabs
    /// down the side, rather than dropping into its place on its way out.
    private var out: Bool { nativeFullscreen || !shut || peek.out }

    var body: some View {
        content(peek.card)
            // As far down as ⌘S's curve has come while it moves it; else
            // where it is, the edge bringing it and letting it go on curves
            // of their own (Brim.bringStrip). Up past the edge its own
            // height, flat, in step with the page's top under it; lifted
            // off the page, just past its shadow too, where the column's
            // card starts (CardMotion.shadow): from further, the spring
            // spent its first frames with nothing to see.
            .modifier(StripPlace(down: nativeFullscreen ? 1 : moving ? down : out ? 1 : 0,
                                 travel: Metrics.row + (peek.card ? CardMotion.shadow : 0)))
            // Pressed while a page has the screen too: WebKit lends the page
            // to a window of its own, on a desktop of its own, and this
            // window's other tabs are still there to use
            // (request 1007).
            .allowsHitTesting(out)
            .accessibilityHidden(!out)
    }
}

/// The window's own drag strip, under everything on a backdrop, clear of
/// what stands at the top: the strip, in its place or out over the page
/// (StripPeek), and the bookmarks.
private struct BackdropDrag: View {
    @ObservedObject var strip: StripPeek
    let reserved: CGFloat
    let trailing: CGFloat
    /// The tabs are across the top.
    let top: Bool
    /// The strip is put away (⌘S).
    let shut: Bool
    let shelf: CGFloat

    var body: some View {
        DragStrip(reserved: reserved, below: (top && (!shut || strip.out) ? Metrics.row : 0) + shelf, trailing: trailing)
    }
}

/// Whatever is drawn in the page's own light or dark, kept up with it as
/// the page is seen again.
struct Shaded<Content: View>: View {
    @ObservedObject var tab: Tab
    @ViewBuilder let content: (ColorScheme?) -> Content

    var body: some View {
        content(tab.isBlank ? nil : tab.shade)
    }
}

/// What stands over a page and wears its light (Tab.under): Peek's
/// buttons, the meeting card.
struct Under<Content: View>: View {
    @ObservedObject var tab: Tab
    @ViewBuilder let content: (ColorScheme?) -> Content

    var body: some View {
        content(tab.isBlank ? nil : tab.under)
    }
}

/// Whatever is drawn in the color the window is painted in: on the site's
/// color, the live tab's, kept up with it, or the swatch, for a page that
/// won't say, for one so white the card would vanish into it, and in a dark
/// window for one too light to sit in it: a bright bar would light the whole
/// frame of a window asked to be dark. On a color, the swatch and nothing else.
///
/// The window's own chrome wears the tab in front's color (Browser.worn),
/// read in this view's own body, so the view that made it isn't drawn again
/// at a switch, and only when that color changes, not at every change of
/// the tab (its title, its progress). A small window of its own follows
/// its one tab (`tab`).
struct Worn<Content: View>: View {
    var tab: Tab?
    var browser: Browser?
    let mode: Backdrop
    let swatch: Tone?
    var glassActive = false
    @ViewBuilder let content: (Tone?) -> Content
    @Environment(\.colorScheme) private var scheme

    init(tab: Tab?, mode: Backdrop, swatch: Tone?, glassActive: Bool = false, @ViewBuilder content: @escaping (Tone?) -> Content) {
        self.tab = tab
        self.mode = mode
        self.swatch = swatch
        self.glassActive = glassActive
        self.content = content
    }

    /// The browser's tab in front, read here rather than in the view that
    /// makes this one, so a switch draws this again and not that.
    init(browser: Browser, mode: Backdrop, swatch: Tone?, glassActive: Bool = false, @ViewBuilder content: @escaping (Tone?) -> Content) {
        self.browser = browser
        self.mode = mode
        self.swatch = swatch
        self.glassActive = glassActive
        self.content = content
    }

    var body: some View {
        if let browser {
            // One shape whatever is in front, so nothing in it is made anew
            // when a tab without a color comes or goes. Taken at once, as the
            // page is: eased, it was drawn again for each frame of 0.14 s.
            let tone = glassActive ? nil : browser.worn.color.map { Tone($0, lifted: true) }
            content(Self.worn(tone, mode: mode, dark: scheme == .dark) ? tone : swatch)
        } else if glassActive {
            content(swatch)
        } else if let tab {
            Toned(tab: tab, lifted: true) { tone in
                content(Self.worn(tone, mode: mode, dark: scheme == .dark) ? tone : swatch)
            }
        } else {
            content(swatch)
        }
    }

    /// Whether the site's color is the one to wear.
    static func worn(_ tone: Tone?, mode: Backdrop, dark: Bool) -> Bool {
        guard mode == .site, let tone, !tone.blank else { return false }
        return !dark || tone.scheme == .dark
    }
}

extension Tone {
    /// The column's words on a site's color: a gray as light as the site,
    /// held to two steps on either side of light and dark, its light or dark
    /// the site's own. The window wears the site's hue behind the column
    /// (Core Animation, nothing redrawn); words in that hue had every row,
    /// word and button of the column drawn again at each switch, some 40 ms
    /// of an M4's main thread (feedback #186). Nil or a tone it can't stand
    /// for (glass, a see-through card), as it is.
    static func columnInk(_ tone: Tone?) -> Tone? {
        guard Narrow.columnInk, let tone, !tone.glass, !tone.seeThrough, !tone.blank else { return tone }
        let (l, _, _) = tone.page.oklch
        let step: CGFloat = tone.scheme == .dark ? (l < 0.42 ? 0.3 : 0.5) : (l < 0.88 ? 0.8 : 0.93)
        var gray = Tone(NSColor(oklch: (step, 0, 0)), lifted: true)
        gray.ink = true
        return gray.scheme == tone.scheme && !gray.blank ? gray : tone
    }
}

/// A shape painted in the ground's color, the color behind it: under the
/// column's gray words on a site's color (Tone.ink), the site's own, read
/// here alone, so a switch paints these again and not the rows round them.
struct GroundFill<S: Shape>: View {
    let shape: S
    var browser: Browser? = nil
    @Environment(\.tone) private var tone

    var body: some View {
        shape.fill(Self.ground(tone, browser: browser))
    }

    @MainActor
    static func ground(_ tone: Tone?, browser: Browser?) -> Color {
        if let tone, tone.ink, let site = (browser ?? BrowserWindows.shared.activeBrowser)?.worn.color { return Color(nsColor: site) }
        return tone?.color ?? Palette.ground
    }
}

/// The ground under the row of tabs edge to edge: the page's own color, or
/// black while the page has the screen. `away` is the window's own word on
/// that (ContentView.frontImmersed), handed in as a value. Read off the tab
/// inside the closure handed to Toned, it was read again only when Toned's
/// body ran for a new tone: the ground went black with a tone read while the
/// page had the screen and stayed black after it came back, the tab no
/// longer immersed, until another tab was chosen (register 2669, 0.47.0).
private struct PageGround: View {
    @ObservedObject var tab: Tab
    let away: Bool

    var body: some View {
        let tone = tab.tone.map { Tone($0) }
        (away ? Color.black : tone?.color ?? Palette.ground)
            .animation(Motion.quick, value: tone)
    }
}

/// The color of the tab in front as the window wears it (Browser.worn).
struct WornSite: Equatable {
    var color: NSColor?
    var tab: Tab.ID?
}

/// The downloads button out of its edge while its place can't be seen: the
/// column or the strip put away or only out over the page for a moment, or
/// a page with the whole screen. With the tabs on top the button is in the
/// strip or the address bar, beside Updates, and never over the page. It
/// watches the card and the strip themselves (SidePeek, StripPeek), which
/// the window's view doesn't.
private struct HoardPlace: View {
    let hoard: Hoard
    @ObservedObject var peek: SidePeek
    @ObservedObject var strip: StripPeek
    let immersed: Bool
    let sidebar: Bool
    /// The column is in its place, showing.
    let docked: Bool
    /// With the tabs on top, the strip is put away (⌘S).
    let stripShut: Bool
    /// The address bar has the doors, the button among them.
    let bandDoors: Bool
    let flank: Flank

    private var away: Bool {
        if immersed { return true }
        guard sidebar else { return stripShut && !strip.out && !bandDoors }
        return !docked && !peek.out
    }

    var body: some View {
        HoardChip(hoard: hoard, away: away, top: !sidebar, flank: flank)
            .onChange(of: away, initial: true) { _, away in
                hoard.away = away
                // The column's cards go with the column.
                if away { hoard.columnWent() }
            }
    }
}

/// A part of the window that draws from the tab in front, made a view of its
/// own so that what it reads is its body's and not the window's: a switch
/// or a navigation runs this again, not the whole window's body
/// (docs/evidence/clean-gap-2026-10-13.md). The content is the same code
/// that stood in the window's body.
struct LiveLeaf<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

/// `content` in a LiveLeaf with YAB_NARROW_LEAVES=1, or in place.
@ViewBuilder
func leaf<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
    if Narrow.leaves { LiveLeaf(content: content) } else { content() }
}

/// The tab in front, followed by a view that draws nothing: `changed` at
/// every change.
private struct ActiveFollow: View {
    let browser: Browser
    let changed: () -> Void
    /// The field coming up or going: it reads the tab in front too
    /// (`fieldShowing` is up over a blank one).
    let field: (Bool) -> Void
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: browser.fieldShowing) { _, showing in field(showing) }
            .onChange(of: browser.activeID) { _, _ in changed() }
    }
}

/// The most the chat's column may take of the window's room, as last
/// measured: read by the body, written without making it again.
final class ChatRoomWidest {
    var widest: CGFloat = .infinity
}

struct ContentView: View {
    @ObservedObject var browser: Browser
    /// The card's edge, dragged (DevSize): the room is laid out again.
    @ObservedObject private var devSize = DevSize.shared

    @State private var keys: Any?
    @State private var middle: Any?
    @State private var window: NSWindow?
    /// Whether the page in front has the screen, as the window's body reads
    /// it: Browser's copy, which changes only when that does, not the tab
    /// itself, which is another object at every switch.
    private var frontImmersed: Bool { Narrow.leaves ? browser.frontImmersed : browser.active?.immersed == true }
    /// The most the chat's column may take of the room (ChatLook.widest).
    /// Written only when it changes how wide the column is drawn: a State
    /// written on every frame of a window resize made the whole window's
    /// body again each frame. The width itself is kept in `chatRoom`.
    @State private var chatWidest: CGFloat = .infinity
    @State private var chatRoom = ChatRoomWidest()
    @Environment(\.colorScheme) private var scheme


    /// The window: room at the top, one stage for the page, and the row when
    /// there is one.
    private var window_: some View {
        let _ = BodyAudit.note("window")
        return ZStack(alignment: .top) {
            // Black while a page has the screen, so the frame of our own window
            // that survives the transition is not a white band across the top.
            // Otherwise the page's own color, so the strip over it reads as
            // the top of the page rather than a band of ours across it, in
            // the row of tabs only; the column is a room of its own.
            //
            // With a backdrop, the backdrop, under everything, the page laid
            // on it, and the window can be moved by any of it that shows.
            // On the site's color it is the page's own, when the page has
            // one: the card then sits on its site's color, and the strip or
            // the column reads as that site's bar. The swatch is for pages
            // that won't say.
            leaf { ZStack(alignment: .top) {
            if let backdrop = backdrop ?? edgeBackdrop {
                Worn(browser: browser, mode: privateWindow ? .color : browser.prefs.backdrop, swatch: Tone(backdrop, lifted: true, glass: glassActive), glassActive: glassActive) { tone in
                    // The look card's switches and drawings (LookCard): the
                    // site's color in one of yours, the colors' turn.
                    LookWorn(browser: browser) { site, step in
                        WindowBackdrop(color: tone?.color ?? Color(nsColor: backdrop), grain: browser.prefs.grain,
                                     transparency: glassActive ? WindowGlassPolicy.transparency(for: tone?.page ?? backdrop) : privateWindow ? 0 : browser.prefs.backdropTransparency,
                                     colors: browser.prefs.backdrop != .site && !privateWindow
                                        ? LookCard.colors(SpacePaint(browser.prefs), dark: scheme == .dark, site: site).map { Color(nsColor: $0) } : [],
                                     glass: glassActive,
                                     drawings: browser.prefs.backdrop != .site && !privateWindow ? LookDrawings.Set(rawValue: browser.prefs.lookDrawings) : nil,
                                     drawingsStrength: browser.prefs.lookDrawingsStrength, step: step).environment(browser)
                    }
                }
                // A space's color going or coming over it (SpaceWash).
                SpaceWashLayer().environment(browser)
                if !carded {
                    // Edge to edge the backdrop is the column's alone: the
                    // rest of the window keeps the plain ground the page
                    // lies on, as it does with no backdrop at all.
                    Palette.ground
                        .padding(browser.flank == .left ? .leading : .trailing, browser.sideShown)
                } else {
                // Not under the tabs: a real view takes a click before
                // anything SwiftUI draws over it, and over the whole window
                // it had every drag on a tab moving the window instead. The
                // row and the column keep strips of their own for the empty
                // parts of them.
                BackdropDrag(
                    strip: browser.topPeek,
                    reserved: browser.prefs.sidebar && browser.flank == .left ? browser.sideShown : 0,
                    trailing: browser.prefs.sidebar && browser.flank == .right ? browser.sideShown : 0,
                    top: !browser.prefs.sidebar, shut: browser.prefs.stripShut, shelf: shelfRoom
                )
                }
            } else if let tab = browser.dresser, !browser.prefs.sidebar {
                PageGround(tab: tab, away: frontImmersed)
            } else {
                Palette.ground
            }
            }
            // Window's mode picked: the new ground at once, under the page
            // that moves to its place. Faded one into the other, both were
            // half there midway, and the window, clear, showed what was
            // behind it through the column for a beat (2026-10-21). On a
            // ZStack, not a Group: a Group hands its modifiers to each
            // branch, and the change between them still faded.
            .animation(nil, value: browser.prefs.backdrop) }
            // The page's color under the strip and the backdrop under the
            // column, one into the other as the tabs change sides.
            .animation(Motion.reshape, value: browser.prefs.sidebar)

            leaf { HStack(spacing: 0) {
                // The room the column of tabs takes, in the way that has one.
                // The column itself is drawn over the window rather than in
                // this row, docked here or floating over the page, it is
                // one surface either way (see Column), and only this room
                // is laid out, so the page makes room for it in the same
                // beat as it changes shape.
                if sidebar && browser.flank == .left {
                    Color.clear
                        .frame(width: browser.sideShown)
                        .transition(.move(edge: .leading))
                }

                VStack(spacing: 0) {
                    // Room for the traffic lights, and for the strip when there
                    // is one. The page starts under it, not behind it, a page
                    // sliding beneath floating chrome is a browser showing off,
                    // and it costs a compositing pass.
                    Color.clear.frame(height: band)

                    // Room for the bookmarks, when they are up. The row
                    // itself is drawn over this room rather than in it (see
                    // `shelf`), so that it can fade out of a room already
                    // given back.
                    Color.clear.frame(height: shelfRoom)

                    // One stage, always, or two side by side (Split.swift).
                    // Each tab on screen keeps its stage for as long as it is
                    // there: a pair coming together keeps the page in front
                    // on the stage it was on, so it can be held and drawn to
                    // its half rather than handed to another view.
                    if let tab = browser.active {
                        // Developer Tools (DevTools.swift): a card of its own
                        // on the backdrop, under the page's card or beside
                        // it, the page making room.
                        // Read only while the tools are out: toolsFront
                        // reads the page's address, and the window's body
                        // ran again at every navigation for it.
                        let devHere = (!Narrow.dev || browser.devOpen || browser.devMoving) && browser.toolsFront != nil
                        let devRim = DevRoom.Rim(card: laid)
                        // A chat in full on the right, the page making room
                        // as it does for the sheet (ChatColumn.swift).
                        ChatRoom(open: browser.chatOpen, rim: devRim, width: chatShown, leading: browser.chatLeads) {
                        DevRoom(open: devHere && browser.devOpen && !browser.devDetached, side: browser.devSide, rim: devRim, height: devSize.height, width: devSize.width) {
                        SplitRoom(drag: browser.splitDrag, preview: browser.splitPreview, share: browser.stagePair?.share ?? 0.5, book: browser.splitBook, measured: { browser.floorWindow() }) {
                            ForEach(0..<2, id: \.self) { slot in
                                if let id = browser.stages[slot], let tab = browser.tabs.first(where: { $0.id == id }) {
                                    half(tab)
                                        .layoutValue(key: SplitLayout.Place.self, value: browser.side(of: id))
                                        .zIndex(browser.wide == id ? 1 : 0)
                                }
                            }
                            if browser.splitShown {
                                SplitDivider(browser: browser, drag: browser.splitDrag, flat: !laid)
                                    .layoutValue(key: SplitLayout.Place.self, value: .gap)
                                    .zIndex(2)
                            }
                        }
                            if devHere && !browser.devDetached && (browser.devOpen || browser.devMoving) {
                                DevSheet(browser: browser, tab: tab, log: tab.devLog, pane: browser.devPane, panels: browser.devPanels, filter: browser.issueFilter, side: browser.devSide,
                                         shown: browser.devOpen, corner: devRim.corner)
                            }
                        }
                            // How wide the card may be beside the page.
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                                browser.measuredDevRoom(size.width)
                                devSize.room = size.height
                            }
                            if browser.chatOpen || browser.chatMoving || !Extensions.all.allSatisfy({ $0.panelPages(in: browser).isEmpty }) {
                                // Moved by Core Animation, in a hosting view
                                // of its own, the air on its left its edge's.
                                ChatColumnHost(browser: browser, shown: browser.chatOpen, corner: devRim.corner, width: chatShown, leading: browser.chatLeads)
                                    .padding(browser.chatLeads ? .trailing : .leading, -Backdrop.inset)
                            }
                        }
                            // How wide the column may be beside the page,
                            // which keeps 400 as beside the developer tools.
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room in
                                let widest = room - devRim.gap - devRim.inset - DevLook.pageBeside
                                ChatLook.widest = widest
                                let was = chatRoom.widest
                                chatRoom.widest = widest
                                if abs(min(browser.chatWidth, was) - min(browser.chatWidth, widest)) > 0.5 { chatWidest = widest }
                            }
                            // Where Open in Chat lands (ChatFlight).
                            .background(FlightMark(kind: .room, inset: devRim.inset))
                            .padding(margins)
                            .overlay(alignment: .topTrailing) {
                                // Its width measured here, where the find bar
                                // is drawn: the half in front's corner follows
                                // the room and the share as they change.
                                GeometryReader { room in
                                VStack(alignment: .trailing, spacing: 0) {
                                    // The half in front's: ⌘F looks through that page.
                                    if browser.finding, let tab = browser.active {
                                        FindBar(finder: tab.finder) { browser.closeFind() }
                                            .padding(.top, Metrics.rim)
                                            .transition(.opacity.combined(with: .offset(y: -4)))
                                    }
                                    // One surface for every notice, coming
                                    // out from under the page's top edge,
                                    // or the find bar's, while it is up.
                                    notices(top: browser.finding ? 8 : Metrics.rim, bar: barHeight)
                                }
                                // The page's own rim, top and right alike,
                                // for everything that floats over it,
                                // measured from the card's edge, not the
                                // window's: this hangs on the page after
                                // its margins, so they are added back. The
                                // top rim is each one's own, so the notice
                                // can be tucked away above it.
                                .padding(.top, margins.top + barHeight)
                                .padding(.trailing, margins.trailing + Metrics.rim + devTrail + frontTrail(in: room.size.width - margins.leading - margins.trailing - devTrail))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                // An agent's question with its home out of
                                // sight stands at the page's bottom right,
                                // its buttons in the corner (AskStand).
                                GeometryReader { room in
                                    AskStandView(browser: browser)
                                        .padding(.bottom, margins.bottom + Metrics.rim)
                                        .padding(.trailing, margins.trailing + Metrics.rim + devTrail + frontTrail(in: room.size.width - margins.leading - margins.trailing - devTrail))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                }
                            }
                    } else {
                        Group {
                            if let under = browser.underTab, !carded || browser.spaceVisiting {
                                // No tab in front: the page you were on as
                                // a space with nothing in it came up, under
                                // the field (Browser.Under). A click on it
                                // is Escape: back to that space.
                                Page(tab: under, corner: corner)
                                    .overlay { if !browser.spaceVisiting { scrim(corner: corner) } }
                            } else if carded {
                                // Nothing to show, or a space with nothing
                                // in it: the page's card kept empty, as Arc
                                // keeps it, not the page you came from
                                // under it. What is behind the window, under
                                // the space's look, read by the backdrop's
                                // light or dark, not the system's.
                                let dark = (backdropTone?.scheme ?? scheme) == .dark
                                EmptyCard(corner: corner, dark: dark, tint: backdrop ?? .windowBackgroundColor,
                                          colors: browser.prefs.backdrop == .color
                                            ? LookCard.colors(SpacePaint(browser.prefs), dark: scheme == .dark, site: nil) : [])
                                    .allowsHitTesting(false)
                                    // A click on it is still Escape: back
                                    // to the space you came from.
                                    .overlay { scrim(corner: corner) }
                            } else {
                                // Nor a backdrop to show: the room a page
                                // takes, in the page's own ground.
                                Palette.ground
                                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                            }
                        }
                        .padding(margins)
                        .overlay(alignment: .topTrailing) {
                            notices(top: Metrics.rim)
                                .padding(.top, margins.top)
                                .padding(.trailing, margins.trailing + Metrics.rim)
                        }
                        // With no page in front too: a question asked of
                        // a tab elsewhere, or of a chat, stands here.
                        .overlay(alignment: .bottomTrailing) {
                            AskStandView(browser: browser)
                                .padding(.bottom, margins.bottom + Metrics.rim)
                                .padding(.trailing, margins.trailing + Metrics.rim)
                        }
                    }
                }
                // Under the card, so that going, the card comes up over it.
                // Drawn where the strip has it while ⌘S moves the strip.
                .background(alignment: .top) {
                    Group {
                        // Beside a column on the right, in a view of its
                        // own, so the band with the lights slides it with
                        // the page by Core Animation (Reshape.slide).
                        if sidebar && browser.headBand && (browser.shelfShown || browser.shelfLeaving) {
                            SlideHost { shelf }
                                .frame(height: shelfHeight)
                        } else {
                            shelf
                        }
                    }
                    .padding(.top, band)
                    .modifier(ShelfCarry(up: browser.stripMoving ? browser.stripDown : stripRoom, shown: stripRoom, shift: Metrics.row))
                }
                // Down, whole, for the band with the lights while it is out
                // (HeadBand), its bottom past the window's: carried, never
                // made shorter, so WebKit lays nothing out and nothing on
                // the page moves. Never stepped by SwiftUI: slid there by
                // Core Animation, then laid out (HeadSunk).
                .modifier(HeadSunk(peek: browser.headPeek, band: sidebar && browser.headBand, laid: laid, shelf: shelfRoom))

                // On the right, the same room after the page.
                if sidebar && browser.flank == .right {
                    Color.clear
                        .frame(width: browser.sideShown)
                        .transition(.move(edge: .trailing))
                }
            }
            // ⌘S moves the column on its curve, but the page is laid out
            // once, where it ends up, and carried there by Core Animation
            // (see `Reshape`): made another size on every frame, WebKit laid
            // the whole page out again each time.
            .transaction { if browser.folding { $0.animation = nil } } }

            // With the column on the right in a window, the lights and the
            // site's name in the room the page makes above itself while the
            // pointer is at the window's top; the column
            // keeps the whole height beside it (HeadBand, Brim).
            leaf { if sidebar && browser.headBand {
                Group {
                    // In the column's ink, on the same backdrop: the title
                    // as quiet as the column's own words, never lost on it.
                    if carded {
                        Worn(browser: browser, mode: browser.prefs.backdrop, swatch: backdropTone, glassActive: glassActive) { tone in
                            HeadBand(browser: browser).toned(tone)
                        }
                    } else {
                        HeadBand(browser: browser)
                    }
                }
                    .padding(.trailing, browser.sideShown)
                    .modifier(HeadShown(peek: browser.headPeek))
                    .transition(.opacity)
            } }

            leaf {
                // Put away by ⌘S, up past the window's top edge, and out
                // over the page while the pointer is at that edge.
                FullscreenToolbar(fullScreen: browser.fullScreen, pinned: !browser.prefs.stripShut,
                                  enabled: !browser.prefs.sidebar || browser.turning) {
                if !browser.prefs.sidebar || browser.turning {
                StripPlaced(peek: browser.topPeek, shut: browser.prefs.stripShut, moving: browser.stripMoving,
                            down: browser.stripDown, nativeFullscreen: browser.fullScreen) { lifted in
                    // In a host of its own, so a change of space turns it in
                    // Core Animation, on screen ahead of the window's own pass
                    // (StripView); its ground stays outside, under the turn.
                    Group {
                        if carded {
                            Worn(browser: browser, mode: browser.prefs.backdrop, swatch: backdropTone, glassActive: glassActive) { tone in
                                StripHost(browser: browser) {
                                    TabBar(browser: browser).background(ChorusInk(chorus: browser.chorus)).toned(tone).modifier(SidebarTypography())
                                }
                                .toned(tone)
                                .background { stripGround(tone, lifted: lifted) }
                            }
                        } else if let tab = browser.dresser {
                            Toned(tab: tab) { tone in
                                StripHost(browser: browser) {
                                    TabBar(browser: browser).background(ChorusInk(chorus: browser.chorus)).toned(tone).modifier(SidebarTypography())
                                }
                                .toned(tone)
                                .background { stripGround(tone, lifted: lifted) }
                            }
                        } else {
                            StripHost(browser: browser) { TabBar(browser: browser).modifier(SidebarTypography()) }
                                .background { stripGround(nil, lifted: lifted) }
                        }
                    }
                    // Only a hint of the way out when the tabs change sides
                    // (see `Presence`); up and out of the way, the whole way,
                    // when a page takes the screen.
                    .modifier(Presence(shown: !browser.prefs.sidebar, edge: .top))
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                }
                }
            }
        }
        .ignoresSafeArea()
        // WebKit already animates its fullscreen window. Resizing our page
        // on each frame adds a second layout animation during the handoff.
        .animation(nil, value: frontImmersed)
        .animation(Motion.glide, value: browser.prefs.backdrop)
        // Not while a space puts its color on: SpaceWash turns it, in the
        // render server, in the switch's own beat.
        .animation(browser.spaceWash.turning ? nil : Motion.glide, value: browser.prefs.swatch)
    }

    /// A page on its stage, with the address bar over it when there is
    /// one: the whole room, or one of two halves side by side, each with a
    /// bar of its own.
    @ViewBuilder
    private func half(_ tab: Tab) -> some View {
        let placed = browser.side(of: tab.id)
        let split = placed != .whole
        let front = tab.id == browser.activeID
        PeekSurface(browser: browser, front: front, corner: corner, padding: margins) {
        // Room made beside the lone page in front (SplitPreview) is watched
        // in here, not by the window: its band takes the half it will have.
        Sided(preview: browser.splitPreview, laid: placed, alone: front && browser.stagePair == nil) { side, warm in
        let split = side != .whole
        let showBar = split || browser.barShown
        VStack(spacing: 0) {
            // The address, when asked for: the card's own top edge, the page
            // under it. Built ahead, out of sight, while a tab is carried
            // over the page (SplitPreview.warm).
            if showBar || warm {
                Toned(tab: tab) { tone in
                    let worn = barTone(tab, tone)
                    AddressBar(
                        browser: browser, tab: tab, peek: browser.peek, strip: !browser.prefs.sidebar,
                        height: AddressBar.height(sidebar: browser.prefs.sidebar, carded: laid), corner: corner,
                        half: split, doors: side != .left,
                        columnDoor: side != .right, leadingInset: margins.leading,
                        leave: split ? { [browser, id = tab.id] in browser.leaveSplit(id) } : nil
                    )
                    .toned(worn)
                    // How tall a half's band is and its corners, for the
                    // divider moved by layers (SplitRule).
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [book = browser.splitBook, corner] in
                        book.bar = $0
                        book.corner = corner
                    }
                    // While the bookmarks come or go, the bar runs on down in
                    // its own color, under the page: the bar is moved by
                    // SwiftUI and the page by Core Animation, a frame or two
                    // apart at the start, and the seam between them would
                    // show the paper.
                    .background(alignment: .bottom) {
                        if browser.shelving || browser.stripMoving {
                            let seam = browser.shelving ? shelfShift : stripShift
                            (worn?.color ?? Palette.ground)
                                .frame(height: seam)
                                .offset(y: seam)
                        }
                    }
                }
                // Drawn where it was while the bookmarks come or go, and
                // brought home with the page.
                .modifier(ShelfCarry(
                    up: browser.shelving ? browser.shelfUp : shelfShown,
                    shown: shelfShown, shift: shelfShift
                ))
                // The same while ⌘S puts the strip away or brings it back.
                .modifier(ShelfCarry(
                    up: browser.stripMoving ? browser.stripDown : stripRoom,
                    shown: stripRoom, shift: stripShift
                ))
                .frame(height: showBar ? nil : 0, alignment: .top)
                .clipShape(BandClip(open: showBar))
                .opacity(showBar ? 1 : 0)
                .allowsHitTesting(showBar)
                .accessibilityHidden(!showBar)
            }
            // Room made for a tab carried over the page (previewSplit): the
            // band goes to its half on SwiftUI's curve, the page and its
            // paper are laid out there at once and drawn there by Core
            // Animation on the same one, WebKit following.
            PageContent(browser: browser, preview: browser.splitPreview, tab: tab, corner: corner, showBar: showBar, front: front)
                .transaction { if browser.splitRooming { $0.animation = nil } }
                // No bar to hold reading mode's book and Aa: they stand in
                // the page's corner while it is read (ReadingPlate).
                .overlay { if !showBar && front { ReadingPlateHost(browser: browser, tab: tab) } }
        }
        }
        // ⌘L's field is the front half's: a click on it puts the field away.
        .overlay { if front { scrim(corner: corner) } }
        // A page taking its time (LoadBar): in the room over the card, as
        // Arc has it, or with no room there, just inside its top on a plate.
        .overlay(alignment: .top) { loadPill(tab) }
        // A chip under the pointer says which half is its, and a half's
        // cross which one would go (SplitHint): watched only here.
        .overlay { if split { HalfHint(hint: browser.splitHint, id: tab.id, corner: corner) } }
        // The link under the pointer, and what a click with the keys held
        // would do with it, at the page's bottom left (LinkStatus).
        .overlay(alignment: .bottomLeading) { LinkStatusPill(tab: tab.id) }
        // Which half is in front, with two on screen: a faint line in the
        // ink round the whole card, band and page, as in Arc. Only once
        // the pair has come together, never over a page still being drawn
        // to its half, and at once when the front changes.
        .overlay {
            if front && browser.splitShown && !browser.splitting && !browser.splitHeld {
                RoundedRectangle(cornerRadius: corner, style: .continuous) // design: the card's own corner, the half is a card
                    .strokeBorder(Color(nsColor: Pair.ring), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .background { pagePaper(tab).transaction { if browser.splitRooming { $0.animation = nil } } }
        }
        // Where each half is, for a click to say which one it fell in.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [book = browser.splitBook, id = tab.id] in
            book.frames[id] = $0
        }
    }

    /// The bar over a page taking its time, its middle in the middle of the
    /// room over the card, or 5 points into the card where there is none
    /// (tabs on top, edge to edge).
    private func loadPill(_ tab: Tab) -> some View {
        let room = margins.top
        let inside = room < 6
        let middle = inside ? 5 + LoadBar.thick / 2 : -room / 2
        return LoadPill(tab: tab, plated: inside)
            .frame(width: LoadBar.size.width, height: LoadBar.size.height)
            .offset(y: middle - LoadBar.size.height / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// A local page's sheet out beside it: the room it takes on the right,
    /// where the notices and the find bar would otherwise stand over it
    /// rather than the page (DevMode.swift).
    private var devTrail: CGFloat {
        let rim = DevRoom.Rim(card: laid)
        let chat = browser.chatOpen && !browser.chatLeads ? ChatRoom.room(rim, width: chatShown) : 0
        guard browser.devOpen, browser.toolsFront != nil, browser.devSide == .right else { return chat }
        return chat + DevLook.width(in: browser.devRoomWidth, wanted: devSize.width) + rim.gap + rim.inset
    }

    /// The chat's column as wide as dragged, less in a room too narrow for
    /// it, as the developer tools beside the page (DevLook.width(in:)).
    private var chatShown: CGFloat { max(ChatLook.least, min(browser.chatWidth, chatRoom.widest)) }

    /// With two halves and the left one in front, the room the right one
    /// takes: the find bar and the notices are about the page in front, and
    /// stand in its corner, not the window's.
    private func frontTrail(in room: CGFloat) -> CGFloat {
        guard browser.splitShown, let pair = browser.stagePair, browser.activeID == pair.first, room > 0 else { return 0 }
        // As SplitLayout places the halves.
        let left = ((room - Pair.gap) * pair.share).rounded()
        return room - left
    }

    // MARK: - the backdrop

    /// What the window is painted in behind the page, for a window of this
    /// brightness, or nil, and the page is the window's ground edge to edge.
    /// Kept while WebKit lends the page to its fullscreen window: tearing
    /// down the material leaves our source window bare during the handoff.
    private var backdrop: NSColor? {
        guard browser.prefs.backdrop != .none else { return nil }
        if privateWindow { return Self.privateBackdrop }
        return browser.prefs.swatch.color(dark: scheme == .dark, custom: browser.prefs.backdropColor)
    }

    /// A private window wears none of your spaces' looks: one dark gray,
    /// in either Appearance, no glass, no colors turning, no drawings, so
    /// it is told apart from every other window at a glance (LookModeScheme
    /// makes it dark).
    private var privateWindow: Bool { browser.windowPurpose == .privateOnly }
    static let privateBackdrop = NSColor(white: 0.12, alpha: 1)

    /// Edge to edge with the column docked, the space's color the window
    /// wears under the column alone (Preferences.edgeBackdrop): the same
    /// backdrop, glass and all, as on a color, the page still edge to edge
    /// and not laid on it as a card (#256).
    private var edgeBackdrop: NSColor? {
        guard browser.prefs.edgeBackdrop else { return nil }
        if privateWindow { return Self.privateBackdrop }
        return browser.prefs.swatch.color(dark: scheme == .dark, custom: browser.prefs.backdropColor)
    }

    /// The space's look is on glass: its color a tint on the window's
    /// Liquid Glass, its words the glass's own (Tone.glass).
    private var glassActive: Bool { browser.prefs.wearsGlass && !privateWindow }

    /// The backdrop as the chrome on it wears it: its brightness decides the
    /// ink, and the live tab is a chip lifted off it.
    private var backdropTone: Tone? {
        backdrop.map { Tone($0, lifted: true, glass: glassActive) }
    }

    private var carded: Bool { backdrop != nil }

    /// The source page keeps its card while WebKit lends its view to a
    /// separate fullscreen window. Its placeholder and return geometry
    /// must stay still; the source stage's corners never clip that window.
    /// In full screen with the tabs put away, the column or the strip, the
    /// page has the screen edge to edge, unless the chat's column or the
    /// developer tools are out, or two halves share the room: then it is a
    /// card beside theirs, in by the same inset, rather than a square edge
    /// against them (Browser.pageShared).
    private var laid: Bool { carded && !(browser.fullScreen && browser.tabsAway && !browser.pageShared) }

    /// The page's corners: a card's, or none, edge to edge.
    private var corner: CGFloat { laid ? Backdrop.corner : 0 }

    /// The page, laid on the backdrop, the same way in from every edge that
    /// has nothing of ours along it. The strip already holds the top, and
    /// the column the left, which, as it goes, hands its edge back to the
    /// margin a point at a time rather than all at once.
    private var margins: EdgeInsets {
        guard laid else { return EdgeInsets() }
        let inset = Backdrop.inset
        let left = browser.flank == .left
        return EdgeInsets(
            top: band == 0 && shelfRoom == 0 ? inset : 0,
            leading: left ? max(0, inset - browser.sideShown) : inset,
            bottom: inset,
            trailing: left ? inset : max(0, inset - browser.sideShown)
        )
    }

    /// The paper under a page with a stage, a layer of its own, so that it
    /// changes shape with the page's (see `Reshape`).
    ///
    /// In the page's own light or dark, not the window's: the page's
    /// corners are cut with soft edges, and a pixel half in the page is
    /// half the paper under it. A white one under a dark site, in a light
    /// window worn dark by the site's color, drew a pale arc round every
    /// corner.
    @ViewBuilder
    private func pagePaper(_ tab: Tab) -> some View {
        if carded {
            Shaded(tab: tab) { shade in
                // Under a hand on the divider the paper follows it as laid
                // out, with nothing drawn from where it was.
                RoomPaper(preview: browser.splitPreview, corner: corner, dark: (shade ?? scheme) == .dark, band: paperBand(tab), moving: browser.reshaping && !browser.trackingSize)
                    .padding(-1)
            }
        }
    }

    /// What the address bar over `tab` wears, given the site's color: a
    /// private tab with nothing of its own to wear is dark, as its page is.
    /// A page on this Mac's own server wears the space's color over its
    /// own, as Arc's dev band does (DevMode.swift). Each half wears its own
    /// site's color, as Arc's do; the window and the column keep their own
    /// look while two are on screen (Browser.dresser), not turning with the
    /// front. Nil, the ground.
    private func barTone(_ tab: Tab, _ tone: Tone?) -> Tone? {
        (tab.isDev ? backdrop.map { Tone($0) } : nil)
            ?? tone ?? (tab.shy ? Tone(NSColor(white: 0.085, alpha: 1)) : nil)
    }

    /// The address bar over `tab`'s page, for the paper under it to wear
    /// the bar's color where the bar's corners are the card's.
    private func paperBand(_ tab: Tab) -> PaperBand? {
        guard browser.barShown || browser.side(of: tab.id) != .whole else { return nil }
        let worn = barTone(tab, tab.tone.map { Tone($0) })
        return PaperBand(
            height: AddressBar.height(sidebar: browser.prefs.sidebar, carded: laid),
            color: worn?.page ?? Palette.NS.ground,
            dark: (worn?.scheme ?? scheme) == .dark
        )
    }

    /// The corner every notice comes out of, and ⌘A's offer over it.
    private func notices(top: CGFloat, bar: CGFloat = 0) -> some View {
        // In a peek's corner while one is up (PeekCorner).
        PeekCornerShift(corner: browser.peekCorner, bar: bar) {
        ZStack(alignment: .topTrailing) {
            // A meeting starting holds the corner; notices come under it.
            CornerNotices(browser: browser, tab: browser.active, top: top)
            // ⌘A's offer, over whatever the corner was saying.
            CopyPill(
                browser: browser,
                copier: browser.pageCopy,
                active: browser.activeID,
                top: top
            )
        }
        }
    }

    /// What rises from the bottom edge: Hide Elements' bar while it picks.
    /// The store's offer only watches from here, and speaks in the corner,
    /// as every notice does (Toast.swift).
    private var bars: some View {
        VStack(spacing: 8) {
            StoreOffer(browser: browser)
            // Capture's bar, for the other mode that picks on the page.
            if browser.veiling {
                ModeFoot(say: "Click to hide · Return to customize") {
                    FootKey("Undo", "⌘Z", .secondary) { browser.undoHiding() }
                    FootKey("Done", "esc", .quiet) { browser.toggleHiding() }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 16)
        .animation(Motion.settle, value: browser.veiling)
    }

    /// A click on the page while ⌘L's field stands over it puts the field
    /// away. Nothing is drawn: as in Arc, the box stands on its own shadow
    /// and the page under it keeps its light. A shade laid on the page
    /// alone stopped at the page's edge, so a dev sheet or the other half
    /// beside it stayed bright and the window read as cut in two.
    @ViewBuilder
    private func scrim(corner: CGFloat) -> some View {
        if browser.fieldShowing, browser.fieldGuest == nil, let tab = browser.active ?? browser.underTab, !tab.isBlank {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .onTapGesture { browser.dismiss() }
                // The page's click is this tap's, as it was before the
                // window's own click away (Browser.fieldAway).
                .background(ClickZone(away: browser.fieldAway))
        } else if browser.fieldShowing, browser.fieldCanPutAway {
            // On the window's own ground, a click beside the field puts it
            // away, the column's tabs free to pick (Browser.backOut).
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .onTapGesture { browser.dismiss() }
        }
    }

    /// The address field: raised over a page by ⌘L or ⌘T, and standing on
    /// its own whenever no tab is in front.
    @ViewBuilder
    private func field(in space: CGSize) -> some View {
            let (lead, trail) = fieldRoom(in: space.width)
            Omnibox(browser: browser, inset: lead, trail: trail,
                    pageTop: band + shelfRoom + margins.top + barHeight, pageBottom: margins.bottom)
                // Keep the native editor and glass prepared with the window.
                // Mounting them on Cmd-L put their first layout and render
                // setup in the opening frame. Hidden fields cannot take
                // clicks, accessibility focus, or keyboard focus.
                // Shown by opacity alone, at the final scale: scaling an
                // AppKit editor rasterizes a new bitmap on every frame.
                // Raised in a small window instead (Browser.fieldGuest): there.
                .opacity(browser.fieldShowing && browser.fieldGuest == nil ? 1 : 0)
                .allowsHitTesting(browser.fieldShowing && browser.fieldGuest == nil)
                .accessibilityHidden(!browser.fieldShowing || browser.fieldGuest != nil)
    }

    /// The room the field stands in the middle of, as what is left of the
    /// window's width on either side: the whole window's, as a launcher
    /// stands in the middle of the screen, the column beside the page
    /// notwithstanding (in the page's middle the box sat off to the right
    /// and read as misplaced); in split view the half in front's, widened
    /// evenly and kept in the window where a half is narrower than the field.
    /// The field can overlap the column, so its width never pushes it away
    /// from the window's middle.
    private func fieldRoom(in width: CGFloat) -> (CGFloat, CGFloat) {
        guard browser.splitShown, let id = browser.activeID, let half = browser.splitBook.frames[id], width > 0 else {
            return (0, 0)
        }
        let need = Metrics.fieldWidth + 32
        guard half.width < need else { return (half.minX, max(0, width - half.maxX)) }
        let lead = min(max(half.midX - need / 2, 0), max(0, width - need))
        return (lead, max(0, width - lead - need))
    }

    /// The panels. All the same kind of thing, so they are built the same way.
    @ViewBuilder
    private var panels: some View {
        // A space's look, in a card over the window it paints (LookCard).
        LookCardLayer(browser: browser)
        BoostEditorLayer(browser: browser)
        // Yab Wrapped's arcade, over the window it was asked in (Wrapped.swift).
        WrappedLayer(browser: browser)
        if browser.welcoming {
            // It covers the whole window, lights and all, and brings its
            // own lights (Welcome.swift).
            WelcomePanel(browser: browser, prefs: browser.prefs)
                .ignoresSafeArea()
        }
    }

    /// The window and what lies right over it: `body`'s first half, apart
    /// for the type checker.
    private var lower: some View {
        window_
            .background(alignment: .topLeading) {
                PageTranslationHost(translation: browser.pageTranslation)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) { bars }
            // With the tabs on top, the update's note, written on the page
            // under the Update button at the end of the strip; under the
            // field and the panels, which are what the window is about
            // while they are open.
            .overlay { UpdateInkOver(browser: browser, prefs: browser.prefs) }
            .overlay { leaf {
                ZStack(alignment: .topLeading) {
                    // Any omnibox can overlap the sidebar. Its tabs, address
                    // buttons and resize handle must stay below the field,
                    // both when drawing and when receiving clicks.
                    card
                        .zIndex(browser.fieldShowing ? 0 : 2)
                    // The field comes and goes with no motion: raised by ⌘T
                    // or ⌘L it is there whole in the next frame, put away it
                    // is gone in that one, full and compact alike, as Arc's
                    // bar (57 ms after the key, no fade, no scale) and
                    // Raycast's window. A 0.22 s fade in read as slowness
                    // (row 1091). Held at nil, so a change made inside
                    // another animation is not faded either.
                    GeometryReader { space in field(in: space.size) }
                        .animation(nil, value: browser.fieldShowing)
                        .zIndex(1)
                }
            } }
            .overlay(alignment: .topLeading) { stillLights }
            // The downloads button out of its edge while its place is out
            // of sight, and the files flying into it, over the page and the
            // column both, since a file crosses from one to the other.
            .overlay { leaf {
                HoardPlace(hoard: browser.hoard, peek: browser.peek, strip: browser.topPeek, immersed: frontImmersed,
                           sidebar: browser.prefs.sidebar, docked: browser.sideShown > 0,
                           stripShut: browser.prefs.stripShut, bandDoors: browser.bandDoors, flank: browser.flank)
                    .ignoresSafeArea()
            } }
    }

    var body: some View {
        let _ = StripRenderMeter.window()
        lower
            // An AppKit view over the window, even one let through, is where
            // SwiftUI's accessibility hit test stops: Magnet and VoiceOver
            // found nothing under it. Those that only draw are hidden from it.
            .overlay { HoardSky(hoard: browser.hoard).allowsHitTesting(false).accessibilityHidden(true).ignoresSafeArea() }
            .overlay { KeyFlightLayer(sky: browser.keySky).ignoresSafeArea() }
            .overlay { TearGround(sky: browser.keySky).ignoresSafeArea() }
            .overlay { ChorusSky(chorus: browser.chorus).allowsHitTesting(false).accessibilityHidden(true).ignoresSafeArea() }
            // ⇧⌘2's outline, picture and card (Capture.swift): a room kept
            // in the window's own stack, empty and let through until then.
            .overlay { CaptureSkyLayer(capture: browser.capture).ignoresSafeArea() }
            // Picking a model, in the middle of the window over everything.
            .overlay { if let request = browser.modelPicker { ModelPickerLayer(browser: browser, request: request) } }
            // What the page in front is asking: in the middle of it for an
            // alert, hanging from its tab for the camera. A tab behind keeps
            // its question until you go back to it.
            .overlay { AskLayer(browser: browser).ignoresSafeArea() }
            // What yab itself asks, an extension to add, ⌘Q, a space to
            // delete, in the middle of the window over all of it dimmed.
            .overlay { QuestionLayer(browser: browser).ignoresSafeArea() }
            // Which tab is which, hanging from the one the pointer rests on.
            .overlay { GlanceLayer(browser: browser, glance: browser.glance).ignoresSafeArea() }
            // Mail's search, over the column's field and past it (MailSearch).
            .overlay { MailSearchLayer(browser: browser) }
            .overlay { panels }
            // Over everything, panels included: it is only ever up while ⌃
            // is held, and whatever is under it is what you are leaving.
            .overlay { SwitcherPanel(browser: browser, switcher: browser.switcher) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                // ⌃ may be let go of in another app, where it can't be heard.
                browser.cancelSwitch()
                browser.appLeft()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                browser.appBack()
            }
            // The page's own window in or out of sight (automatic PiP, as
            // Chrome decides it from the tab's view): this browser window,
            // or the one its page in front was lent for full screen.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                guard let changed = note.object as? NSWindow else { return }
                browser.sightChanged(of: changed)
            }
            // A window sliding in or out of full screen: its occlusion means
            // nothing meanwhile (`Browser.sightSliding`).
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
                if let window = note.object as? NSWindow { browser.fullscreenSlide(window, started: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
                if let window = note.object as? NSWindow { browser.fullscreenSlide(window, started: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
                if let window = note.object as? NSWindow { browser.fullscreenSlide(window, started: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
                if let window = note.object as? NSWindow { browser.fullscreenSlide(window, started: false) }
            }
            .background(WindowSetup(prepare: { LaunchArrival.shared.prepare($0, primary: browser.windowID == nil) }) {
                window = $0; dress($0)
            })
            // The tab in front followed in a leaf of its own, not in the
            // window's body (LiveLeaf).
            .background {
                ActiveFollow(browser: browser, changed: { handBack() }, field: { showing in
                    if showing {
                        // The field has the keys: a page's file list goes, and
                        // the page hears that no file came.
                        if browser.query.place != .files { browser.dropFiles() }
                        DispatchQueue.main.async { browser.askFocus() }
                    } else {
                        handBack(fromFieldDismissal: true)
                    }
                })
            }
            .animation(Motion.settle, value: browser.welcoming)
        .onAppear {
            browser.menuFront.follow(browser)
            watchKeys()
            browser.askFocus()
            // Addresses from other apps have somewhere to go from here on.
            if browser.windowID == nil { Links.hand(to: browser) }
            // What is copied, kept for the field's Clipboard History.
            if browser.windowID == nil { Clips.shared.start(for: browser) }
            browser.followHints()
            // Habits counted once the window is up, not in its way: the
            // first empty field then has them at once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Hints.shared.compose() }
            if browser.windowID == nil { BookmarkMenu.shared.start(for: browser) }
        }
        .onDisappear {
            if let keys { NSEvent.removeMonitor(keys); self.keys = nil }
            if let middle { NSEvent.removeMonitor(middle); self.middle = nil }
        }
    }

    /// Give the keyboard back to the page once the field is done with it.
    ///
    /// Nothing did this before, so after typing an address the window's first
    /// responder was a text field that no longer existed: typing went nowhere
    /// until you clicked the page. It also mattered more than it looked,
    /// WebAuthn refuses to run on a document that isn't focused, and so do a
    /// number of paste and shortcut handlers pages install for themselves.
    private func handBack(fromFieldDismissal: Bool = false) {
        guard !browser.fieldShowing, browser.editingTab == nil else { return }
        DispatchQueue.main.async {
            guard !browser.fieldShowing, browser.editingTab == nil,
                  !(fromFieldDismissal && browser.query.pasteStyleTarget.consumeRestoredFocus()),
                  let page = browser.active?.page, let window = page.window else { return }
            window.makeFirstResponder(page)
        }
    }

    // MARK: - the window

    /// True while the tabs are down the left.
    private var sidebar: Bool {
        browser.prefs.sidebar
    }

    /// True while the tabs are down the left but the column is put away.
    /// It comes out over the page from the left edge.
    private var shut: Bool {
        sidebar && browser.prefs.sideShut
    }

    // MARK: - the strip put away

    /// The strip in its place, as a number, for what rides with it as ⌘S
    /// moves it (`ShelfCarry`): 1, or 0 put away.
    private var stripRoom: CGFloat {
        browser.stripAway ? 0 : 1
    }

    /// How far the card's top moves as the strip goes or comes: the strip's
    /// height, less the inset a card keeps from the window's top once
    /// nothing is over it. Whether it is a card then is asked of the strip
    /// put away, not of now: in full screen the page with the strip away is
    /// edge to edge, its top at the screen's, so it moves the whole row
    /// both ways, where the card it becomes as the strip comes back would
    /// have taken off the inset and carried the address bar 8 points short.
    private var stripShift: CGFloat {
        Self.stripStep(carded: carded, full: browser.fullScreen, chat: browser.pageShared, shelf: shelfRoom > 0)
    }

    static func stripStep(carded: Bool, full: Bool, chat: Bool, shelf: Bool) -> CGFloat {
        // A card with the strip away, as `laid` has it then.
        let laid = carded && !(full && !chat)
        return Metrics.row - (laid && !shelf ? Backdrop.inset : 0)
    }

    /// What the strip lies on while it is put away and out over the page:
    /// the window's backdrop on a ground of its own, as the column's card
    /// wears it, or, edge to edge, the color the window wears there; with a
    /// hairline along its foot on a backdrop, and a card's shadow, to lift it
    /// off the page, which stays as it is under it. Nothing in its place,
    /// where the window's own ground is under it, nor going away by ⌘S, when
    /// it leaves as it was there.
    @ViewBuilder
    private func stripGround(_ tone: Tone?, lifted: Bool) -> some View {
        // In full screen the strip steps down under macOS's menu bar, out
        // over the page, which stays where it was: grounded there too.
        let over = lifted || browser.menuOut || browser.fullScreen
        if browser.stripAway || browser.stripMoving || browser.menuOut || browser.fullScreen {
            ZStack(alignment: .bottom) {
                if carded, let tone {
                    CardGround(paint: Column.paint(tone, prefs: browser.prefs)).environment(browser)
                } else {
                    tone?.color ?? Palette.ground
                }
                if carded {
                    Rectangle().fill(Palette.ink.opacity(0.1)).frame(height: 1).toned(tone)
                }
            }
            .compositingGroup()
            .shadow(color: .black.opacity(Double(Shadow.card.opacity)), radius: Shadow.card.radius, y: Shadow.card.y) // design: the column card's shadow, Shadow.card; a see-through backdrop can't cast it from a black shape
            .opacity(over ? 1 : 0)
            // On at once, out of sight past the edge, as the edge's spring
            // starts; off on ⌘S's curve, as the page makes room under it.
            .transaction(value: over) { if over { $0.animation = nil } }
            .allowsHitTesting(false)
        }
    }

    /// The column of tabs, drawn over the window rather than laid out in it:
    /// docked in its place beside the page, or floating over the page, in
    /// full screen, or put away and brought out from the edge. One view for
    /// all of it, so pinning is a change of shape and never a swap. It is
    /// always there while the tabs are down the left, if only past the edge.
    @ViewBuilder
    private var card: some View {
        if browser.prefs.sidebar || browser.turning {
            ColumnHost(browser: browser, prefs: browser.prefs)
                .ignoresSafeArea()
                .modifier(Presence(shown: browser.prefs.sidebar, edge: browser.flank.edge))
                // Its rows choose tabs while a video plays full screen: the
                // video is in WebKit's window, on its own desktop, and this
                // one stays usable (request 1007).
                .transition(.move(edge: browser.flank.edge))
        }
    }

    /// The lights while the tabs change sides: one set, where both the strip
    /// and the column keep them, Lights.first in to the first one's center,
    /// stepping down or up the six points between the strip's height and the
    /// column's top band, in the same beat as the page.
    @ViewBuilder
    private var stillLights: some View {
        if browser.stillLights {
            Lights()
                .frame(width: Lights.run, height: Metrics.row)
                .padding(.leading, Lights.first - Lights.lead)
                // Moved, not laid out again: an offset is only drawn.
                .offset(y: browser.prefs.sidebar ? (Metrics.strip - Metrics.row) / 2 : 0)
                .animation(Motion.reshape, value: browser.prefs.sidebar)
                .ignoresSafeArea()
        }
    }

    // MARK: - the bookmarks bar

    /// The room the bookmarks take over the page, or none.
    private var shelfRoom: CGFloat {
        browser.shelfShown ? shelfHeight : 0
    }

    /// How tall that room is when there is one: level with the lights
    /// beside the column where they stand, a plain row anywhere else.
    private var shelfHeight: CGFloat {
        sidebar && !shut && browser.flank == .left ? BookmarkBar.besideLights : BookmarkBar.height
    }

    /// The row is up, as a number for `ShelfCarry`.
    private var shelfShown: CGFloat { browser.shelfShown ? 1 : 0 }

    /// How far the card moves down when the row comes: its room, less the
    /// inset it had above it on a backdrop, which the room takes over.
    private var shelfShift: CGFloat {
        shelfHeight - (laid && band == 0 ? Backdrop.inset : 0)
    }

    /// The row, over its room, in whatever the chrome round it wears: the
    /// backdrop, or, edge to edge with the tabs on top, the page's color.
    /// Never faded: it lies still under the card, which moves off it coming
    /// and back over it going, so the row is uncovered rather than shown.
    @ViewBuilder
    private var shelf: some View {
        if browser.shelfShown || browser.shelfLeaving {
            Group {
                if laid {
                    Worn(browser: browser, mode: browser.prefs.backdrop, swatch: backdropTone, glassActive: glassActive) { tone in
                        shelfRow.toned(tone)
                    }
                } else if !sidebar, let tab = browser.dresser {
                    Toned(tab: tab) { tone in shelfRow.toned(tone) }
                } else {
                    shelfRow
                }
            }
            .allowsHitTesting(browser.shelfShown)
        }
    }

    private var shelfRow: some View {
        BookmarkBar(
            browser: browser, bookmarks: browser.bookmarks,
            height: shelfHeight,
            top: shelfHeight == BookmarkBar.besideLights ? Metrics.strip / 2 - BookmarkBar.row / 2 : (shelfHeight - BookmarkBar.row) / 2,
            lead: laid ? margins.leading : AddressBar.shelfRim,
            trail: laid ? margins.trailing : AddressBar.shelfRim,
            style: browser.prefs.bookmarkStyle
        )
    }

    /// The address bar's height, or nothing while there is none.
    private var barHeight: CGFloat {
        browser.barShown ? AddressBar.height(sidebar: browser.prefs.sidebar, carded: laid) : 0
    }

    /// The column has its own corner for the lights, so the page beside it
    /// starts at the very top. A column put away leaves nothing behind,
    /// no band, no lights, no doors: the page has the whole window, and
    /// all of that comes back with the card out of the left edge. Only the
    /// strip needs a band, and not once it is put away, which leaves as
    /// little behind as the column does.
    private var band: CGFloat {
        Self.bandHeight(sidebar: sidebar, stripAway: browser.stripAway)
    }

    static func bandHeight(sidebar: Bool, stripAway: Bool) -> CGFloat {
        // The strip put away (⌘S) leaves no band either: it comes out over
        // the page from the window's top edge, as the column from the left.
        guard sidebar else { return stripAway ? 0 : Metrics.row }
        // With the column on the right, the band with the lights takes no
        // room either: the page is carried down under it whole (`headSink`).
        return 0
    }

    /// How far the page goes down while the band with the lights is out,
    /// beside a column on the right (HeadBand): to a row from the top, as
    /// under a title bar, from the inset it had on a backdrop.
    static func headSink(out: Bool, laid: Bool, shelf: CGFloat) -> CGFloat {
        guard out else { return 0 }
        return Metrics.row - (laid && shelf == 0 ? Backdrop.inset : 0)
    }

    private func dress(_ window: NSWindow) {
        BrowserWindows.shared.register(window, for: browser)
        if browser.windowID == nil { Links.window = window }
        Startup.mark("dressed")
        Startup.watch(window)
        SplitDeck.warm()
        browser.hoard.watch(window)
        // Light or dark is the app's to say (Settings › Appearance); the
        // window only has to be the ground color that goes with it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        // Movable, for macOS: Window › Fill, Center and Move & Resize, the
        // green button's menu and the tiling at the screen's edges all ask.
        // It was not, while AppKit dragged it by the band a title bar would
        // have, tabs and all: a drag on a tab moved the window and never
        // reached the tab. AppKit drags it by nothing now, only the strips
        // move it, where nothing else is (WindowDrag, DragStrip), and the
        // page underneath can't be grabbed by accident while selecting text.
        WindowDrag.keep(window)
        // Where you left it, at the size you left it. A test run keeps its
        // own: the name lives in the app's standard defaults, which every
        // copy shares, and a probe resized for a test once changed the size
        // the real window came back at.
        Startup.stage("window frame") {
            if browser.windowPurpose == .normal {
                WindowFrameAutosave.keep(window, name: BrowserWindows.shared.frameAutosaveName(
                    for: browser.windowID ?? BrowserWindows.primaryID), restoring: true)
            }
        }

        // The traffic lights are part of the layout, not of the title bar,
        // see Lights.swift. The title bar's own are put away, but for full
        // screen, which is looked after by Brim.
        Lights.hideOwn(of: window)
        Brim.keep(window, for: browser)
        // Glass stays lit behind other apps, see Awake.swift.
        Awake.keep(window)
        // Opened by the disk image: over its window, then to size.
        Arrival.receive(window)
    }

    /// The tab of the column's row the window has at `point` (its own, from
    /// its bottom left): the row the pointer is on as drawn, whatever
    /// hovering has heard yet. A pair's halves validate hover against
    /// their hit cell; a folder or an empty area says nothing.
    private static func columnTab(at point: NSPoint, in window: NSWindow, hovered: Tab?) -> Tab.ID? {
        var view = window.contentView?.superview?.hitTest(point)
        while let each = view, !(each is ColumnCell) { view = each.superview }
        guard let cell = view as? ColumnCell else { return nil }
        return cell.tabUnderPointer(hovered: hovered)
    }

    // MARK: - keys

    /// A web view takes first responder and keeps most of the keyboard, so the
    /// shortcuts are caught before the event ever reaches it. The menu carries
    /// the same commands for anyone looking for them, and never sees these
    /// keystrokes because this runs first.
    private func watchKeys() {
        guard keys == nil else { return }
        KeyNumbers.shared.watch()
        // The middle button on a tab closes it, as in every other browser; a
        // pin is put down, as ⌘W puts one down, and a kept tab put down
        // leaves the kept (Browser.middleShut). One watcher for the app, by
        // the tab under the pointer, rather than a view over every tab: on
        // the release, and only if it is still over the tab it was pressed
        // on, so a press by mistake is taken back by moving off. The tab
        // under it is the one drawn there (KeySky.stripTab); what hovering
        // last said only where no tab is known to be.
        var pressed: Tab.ID?
        middle = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { event in
            guard event.buttonNumber == 2 else { return event }
            // Every release ends the gesture, including one outside the
            // tabs or in another window. A second release closes nothing.
            let began = pressed
            pressed = nil
            guard NSApp.isActive, let window, event.window === window,
                  let content = window.contentView else { return event }
            // Over the tabs, the strip across the top or the column down the
            // side, and nowhere else.
            let spot = event.locationInWindow
            let column = browser.prefs.sidebar
            // A hover card reserves no width beside the page (sideShown
            // is zero), but its visible rows still take the middle button.
            let columnWidth = browser.sidePeek ? Metrics.floatInset + browser.prefs.sideWidth : browser.sideShown
            let overTabs = column
                ? (browser.flank == .left ? spot.x < columnWidth : spot.x > content.bounds.width - columnWidth)
                : content.bounds.height - spot.y < Metrics.strip
            guard overTabs else { return event }
            // Across the top, by where each tab is drawn; down the side, by
            // the row the window has under the pointer. Hovering alone was
            // late after the rows moved, their places told on the next move
            // (ColumnQuiet), and a press with no move between went nowhere.
            let drawn = column
                ? Self.columnTab(at: spot, in: window, hovered: browser.tabs.first { $0.id == browser.glance.pointed })
                : browser.keySky.spot(spot, in: window).flatMap { at in
                    browser.keySky.stripTab(at: at, among: browser.tabs.map(\.id))
                }
            let under = drawn ?? (column && ColumnKit.on ? nil : browser.glance.pointed)
            if event.type == .otherMouseDown {
                pressed = under
                return under == nil ? event : nil
            }
            guard let id = under, id == began else { return event }
            if let tab = browser.tabs.first(where: { $0.id == id }) { browser.middleShut(tab) }
            return nil
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // A page's own full screen, a video's, is WebKit's window over
            // this one: its tab keys are this window's (register 939).
            if event.window !== window, let window, Self.fromPageFullScreen(event, browser: browser, window: window) { return nil }
            guard event.window === window else { return event }
            // The settings window has keys of its own.
            if event.window is SettingsFrame { return event }
            // A shortcut being recorded is given every key, ⌘T included.
            if Keymap.shared.recording { return event }
            // So does a small window for a link (LinkWindow.listen).
            if LinkWindow.owning(event.window) != nil { return event }
            // And the floating video, whose Esc, Return and arrows are its own.
            if Floater.owns(event.window) { return event }
            guard event.type == .keyDown else {
                if browser.selectionCommands.stage == .preview {
                    browser.selectionCommands.showOriginal = event.modifierFlags.contains(.option)
                }
                // Letting go of the chosen recent-tab modifier ends the walk.
                let held = Keymap.shared.keys(.recentTab)?.flags ?? .control
                let reverse = Keymap.shared.keys(.recentTabReverse)?.flags ?? [.control, .shift]
                if !event.modifierFlags.contains(held) && !event.modifierFlags.contains(reverse) { browser.landSwitch() }
                return event
            }
            if Store.testing { Bench.heard(event) }
            return take(event) || mailKeeps(event) ? nil : event
        }
    }

    /// The keys that open the field or go to another tab, pressed while the
    /// page in front has the screen in WebKit's own window (a video's full
    /// screen button, YouTube's F). That window, not this one, has the keys,
    /// so ⌃Tab went nowhere, and ⌘T's field opened here, under the video,
    /// unseen (register 939). The page's full screen is left first, as
    /// Chrome and Safari leave it, and the key is pressed again here.
    private static let leavesPageFullScreen: Set<Shortcut.Action> = [
        .newTab, .newTabInFolder, .openAddress, .recentTab, .recentTabReverse, .nextTab, .previousTab,
        .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9,
    ]

    private static func fromPageFullScreen(_ event: NSEvent, browser: Browser, window: NSWindow) -> Bool {
        guard event.type == .keyDown, let shown = event.window, let tab = browser.active, tab.immersed,
              tab.builtPage?.window === shown, !Keymap.shared.recording,
              let action = Keymap.shared.action(for: event)?.action, leavesPageFullScreen.contains(action) else { return false }
        if event.isARepeat { return true }
        let flags = event.modifierFlags, chars = event.characters ?? "", bare = event.charactersIgnoringModifiers ?? "", code = event.keyCode
        browser.leavePageFullScreen { [weak window] in
            guard let window else { return }
            window.makeKeyAndOrderFront(nil)
            guard let again = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: chars, charactersIgnoringModifiers: bare,
                                               isARepeat: false, keyCode: code) else { return }
            NSApp.postEvent(again, atStart: false)
            // ⌃ let go of while the page was coming back: a tap, which
            // lands on the tab it named rather than leaving the grid up.
            guard action == .recentTab || action == .recentTabReverse else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let held = Keymap.shared.keys(action)?.flags ?? .control
                if browser.switcher.open, !NSEvent.modifierFlags.contains(held) { browser.landSwitch() }
            }
        }
        return true
    }

    /// Keys kept from the page under mail, for the bench.
    @MainActor static var mailKept = 0

    /// A plain key nothing took (no ⌘, ⌃ or ⌥) while mail's page is in front
    /// and the keyboard is on no words: kept from the page under mail, its
    /// ground or a mail's own HTML. WebKit would send a key no page used
    /// back through the app a moment later, into whatever had the keyboard
    /// then: a field that opened meanwhile got the letter typed before it.
    /// With the keyboard nowhere, it is kept too: a beep says nothing here.
    private func mailKeeps(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, browser.inMail, MailPage.isMail(browser.active?.address), !browser.fieldShowing,
              browser.peeking == nil, !browser.chatAttach.typing,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let responder = event.window?.firstResponder
        guard responder == nil || responder === event.window || responder is PageView || responder is MailBodyView else { return false }
        ContentView.mailKept += 1
        return true
    }

    /// The last key handed to the page before yab acted on it (see
    /// `pageFirst`): if WebKit sends it back unused, it is yab's.
    private static var passed: NSEvent?

    /// A key a page may want for itself, ⌘F in a Google Doc, ⌘K in Slack,
    /// ⌘D in Figma, ⌘P in an editor, goes to the page first,
    /// and is yab's only if the page leaves it unused: WebKit then sends
    /// the same event back through the app, and it comes here a second
    /// time. Only while the page has the keyboard; in the address field or
    /// a panel, yab's keys are yab's. The keys that make, close and move
    /// between tabs stay yab's first, as a browser keeps them its own, and so
    /// does ⇧⌘V, which no page has a use for: `reserved`, for the ones
    /// Settings › Shortcuts can change whatever keys they have now
    /// (Shortcut.first).
    private func pageFirst(_ event: NSEvent, reserved: Bool) -> Bool {
        // Mail's page is only a ground under what the app draws (MailPage):
        // it has no use for a key, and handing it one is a trip to WebKit
        // and back for nothing, lost on the way when Yab isn't the active app.
        let responder = event.window?.firstResponder
        guard !reserved, let page = (responder as? PageView).map({ $0.url }) ?? (responder as? ChromiumPage).map({ $0.url }),
              !MailPage.isMail(page) else { return false }
        if let passed = ContentView.passed, PageView.same(passed, event) {
            ContentView.passed = nil
            return false
        }
        ContentView.passed = event
        return true
    }

    /// The keys of the top row, by where they sit rather than what they type.
    static let digits: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
    ]

    /// Read-only text can be selected without taking the finished chat's Done.
    @MainActor static func textResponderOwnsDone(_ responder: NSResponder?) -> Bool {
        (responder as? NSText)?.isEditable == true
    }

    func take(_ event: NSEvent) -> Bool {
        // Words an input method is still composing, in a field or on a
        // page: Return, Escape, Space, Tab and the arrows are its, to
        // commit or pick a candidate (Find's Escape would close the bar).
        // ⌘ and ⌃ keys stay the app's, as in every Mac app.
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .control]).isEmpty,
           InputMethod.composing(event.window?.firstResponder) { return false }
        // A modal question stands above every browser tool, even while the
        // omnibox's native field editor keeps focus for Cancel to return to.
        // Only in its own window: the others go on under their own keys (#1097).
        if Questions.shared.current?.place == .page, !SettingsCards.owns(event.window),
           Questions.shared.stands(in: event.window) {
            return Questions.shared.key(event)
        }
        // Yab Wrapped's arcade up over this window: Esc is its, before
        // anything under it hears the key (Wrapped.swift).
        if Wrapped.shared.model != nil, Wrapped.shared.browser === browser, Wrapped.isEscape(event) {
            Wrapped.shared.close()
            return true
        }
        // ⌃⌘F, full screen in every Mac app (Keymap.system), from the page,
        // the field or anywhere (register #440). Since macOS 15 the View
        // menu's Enter Full Screen that AppKit puts in wears fn F only, so
        // nothing else answers ⌃⌘F. By where the key sits, as the F key.
        if event.keyCode == 3,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.control, .command],
           let window = event.window, window.collectionBehavior.contains(.fullScreenPrimary) || window.styleMask.contains(.resizable) {
            // Held down, it goes once.
            if !event.isARepeat { window.toggleFullScreen(nil) }
            return true
        }
        // fn F and the other keys the menus hold with fn, before the page's
        // WebKit view takes them as it takes the arrows (register #1693).
        if Keymap.pressFunctionItem(for: event) { return true }
        // Chrome's DevTools have the keys they have in Chrome.
        if ChromiumDevKeys.take(event) { return true }
        // Network's table has keys of its own, Chrome's: ⌘K clears there.
        if NetKeys.take(event, browser: browser) { return true }
        // The card's own: ⇧⌘P, ⌘P, Escape for the drawer, ⌘K in Console.
        if DevKeys.take(event, browser: browser) { return true }
        // Editing inside DevTools belongs to its native fields or bundled editor.
        if browser.devOpen {
            let responder = (event.window ?? NSApp.keyWindow)?.firstResponder
            if DevKeys.contains(responder) { return false }
        }
        // A dialog's confirmation keys come before Mail, capture and the
        // page's commands. Mail also uses Return and Escape for its rows
        // and drafts, so asking the dialog later lets those take its keys.
        if Questions.shared.key(event, typing: browser.active?.typing == true) { return true }
        // A question's text field keeps editing keys in AppKit, without
        // Mail interpreting Escape as closing the draft underneath it.
        if let question = Questions.shared.current, question.field != nil,
           SettingsCards.owns(event.window) == (question.place == .settings),
           event.window?.firstResponder is NSText { return false }
        if let tab = browser.active, browser.askKey(event, on: tab) { return true }

        // A capture being picked or looked at has Escape, Return, F and the
        // arrows while it is up (Capture.swift).
        if browser.capture.take(event) { return true }
        // Fill & Sign's mode has its esc, ⌘↩, ⌘Z, Tab and Return (PDFDesk.swift).
        if let tab = browser.active, tab.paper.desk != nil, tab.paper.take(event, tab: tab, browser: browser) { return true }
        // Mail's own keys while its page is in front (MailDesk.key).
        if browser.inMail, !browser.fieldShowing, !browser.chatAttach.typing,
           browser.peeking == nil, MailPage.isMail(browser.active?.address),
           MailDesk.shared.key(event, in: event.window, browser: browser) { return true }
        // A new mail over the page (MailtoPeek.swift): ⌘W puts it away, ⌘O
        // goes on in mail's page; a draft's keys are mail's, esc too.
        if browser.mailtoFrom != nil, !browser.fieldShowing {
            if Keymap.shared.matches(event, .closeTab) { browser.closeMailto(); return true }
            if Hotkeys.shared.matches(event, "Open Peek as Tab") { browser.keepMailto(); return true }
            if MailDesk.shared.key(event, in: event.window, browser: browser) { return true }
        }
        // A thread over the page (MailThreadPeek): esc or ⌘W puts it away,
        // ⌘O goes on in mail's space.
        if browser.threadPeek != nil, !browser.fieldShowing {
            let bare = event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
            if Keymap.shared.matches(event, .closeTab) || (bare && event.keyCode == 53) { browser.closeThreadPeek(); return true }
            if Hotkeys.shared.matches(event, "Open Peek as Tab") { browser.keepThreadPeek(); return true }
        }
        // An agent's tab looked at from mail (MailChat): Escape is back to
        // the email, the tab working on unseen.
        if MailChat.lookedAt(in: browser), !browser.fieldShowing, !browser.chatAttach.typing, browser.peeking == nil,
           event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty, event.keyCode == 53 {
            MailChat.backToMail(in: browser)
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = Hotkey(event)?.key ?? ""
        // ⌘N with the chat's field focused (⌘J): a new chat, not a window.
        if browser.chatOpen, browser.chatAttach.typing,
           event.window?.firstResponder is NSTextView,
           Keymap.shared.matches(event, .newWindow) {
            if !event.isARepeat { browser.newChat() }
            return true
        }
        // ⌘V of a picture, or of files copied in the Finder, into the
        // chat's field: chips, as a drop makes them. Words paste as words.
        if browser.chatOpen, browser.chatAttach.typing,
           event.window?.firstResponder is NSTextView, ChatAttach.isPaste(event),
           browser.chatAttach.paste(from: .general, chat: Chats.shared.chat(browser.chatID), browser: browser) {
            return true
        }
        // ⌘C in the chat's field with nothing picked: Copy Again, when the
        // chat's last turn put something on the clipboard (ChatCopiedLine).
        if browser.chatOpen, browser.chatAttach.typing,
           let editor = event.window?.firstResponder as? NSTextView, editor.selectedRange().length == 0,
           Keymap.shared.matches(event, .answerCopy),
           let clip = ChatItem.lastClip(Agents.shared.session(browser.chatID)?.items ?? []),
           AgentClips.shared.pressAgain(clip) {
            return true
        }
        // A focused finished chat owns its completion keys even if another
        // tab currently has an agent driving it.
        if browser.chatOpen, browser.chatAttach.typing,
           event.window?.firstResponder is NSTextView,
           let chat = browser.chatAttach.finishableChatID {
            if Keymap.shared.matches(event, .chatDoneKeep) {
                Agents.shared.finish(chat, in: browser, keepingTabs: true)
                return true
            }
            if Keymap.shared.matches(event, .chatDone) {
                Agents.shared.finish(chat, in: browser, keepingTabs: false)
                return true
            }
        }
        // Take Over shares ⌘. with Stop Loading by default. While an agent
        // controls this tab, Take Over has the key; otherwise loading keeps it.
        if Keymap.shared.matches(event, .agentTakeWheel),
           let tab = browser.active, let session = Agents.shared.session(tab.worker),
           session.state.live, !session.script, !AgentFeed.shared.driving.contains(tab.id),
           tab.handoff == nil {
            AgentFeed.shared.drive(tab)
            return true
        }
        if Keymap.shared.matches(event, .agentStop), let tab = browser.active,
           Agents.shared.stop(on: tab) { return true }
        if Keymap.shared.matches(event, .agentHandBack),
           let tab = browser.active, AgentFeed.shared.driving.contains(tab.id) {
            AgentFeed.shared.handBack(tab)
            return true
        }
        if Keymap.shared.matches(event, .closeChat) {
            if !event.isARepeat { browser.toggleChat() }
            return true
        }
        // ⌘J again from the chat it brought out: the column away, not a
        // second ask (register 1130).
        if Keymap.shared.matches(event, .agentAsk), browser.askClosesChat {
            if !event.isARepeat { browser.hideChat() }
            return true
        }
        if !browser.fieldShowing, let tab = browser.active, tab.builtPage != nil,
           browser.selectionCommands.take(event, on: tab) { return true }
        // A snippet's own key, into the box the caret is in (PageSnippets).
        if PageSnippets.shared.hotkey(event, browser: browser) { return true }

        // A key a page had first and left unused, back from WebKit: straight
        // to yab's command, not through everything before it a second time.
        if let passed = ContentView.passed, PageView.same(passed, event) {
            ContentView.passed = nil
            if let action = Hotkey.first(event, { QuickActions.shared.action(for: $0) })?.1 {
                browser.run(action)
                return true
            }
            return commands(event, key: key, shifted: flags.contains(.shift))
        }

        if browser.fieldShowing, browser.query.place == .files, event.keyCode == 49,
           flags.intersection([.command, .option, .control, .shift]).isEmpty,
           browser.toggleFileSelection() { return true }

        // While ⌃Tab's grid is up every key is its: Tab and the arrows walk,
        // Return and a let-go ⌃ land, Escape stays where you were.
        if browser.switcher.open {
            if Keymap.shared.matches(event, .recentTab) { browser.switchStep(1); return true }
            if Keymap.shared.matches(event, .recentTabReverse) { browser.switchStep(-1); return true }
            switch event.keyCode {
            case 123, 124, 125, 126: browser.switchMove(event.keyCode)
            case 36, 76: browser.landSwitch()
            case 53: browser.cancelSwitch()
            // ⌃W closes the tile walked to: ⌃ is still held, or the grid
            // would have landed.
            default: if key == "w", flags.intersection([.command, .option, .shift]).isEmpty { browser.closeSwitched() }
            }
            return true
        }

        // A card at the page's foot has a few keys of its own while it is
        // there: ⌘↩ sends its draft, ⌘R rewrites it rather than reloading.
        if AnswerKeys.shared.take(event, in: browser) { return true }

        // Numbered answers on an agent's question are physical number keys,
        // with their labels and assignments from the same shortcut slot.
        if let tab = browser.active, !tab.choices.isEmpty, !tab.typing, !browser.chatAttach.typing {
            for (index, choice) in tab.choices.prefix(9).enumerated() {
                if let action = Shortcut.numbered("agentChoice", index + 1), Keymap.shared.matches(event, action) {
                    Agents.shared.choose(tab, choice)
                    return true
                }
            }
        }

        // ⌘A on a page offers it whole (PageCopy.swift): ⌘C copies as
        // always and says so, the keys chosen for Markdown and the file
        // (none unless chosen) are the offer's only while it is up, and any
        // other key puts it away and goes on as it would have.
        let only = flags.intersection([.command, .option, .control, .shift])
        if browser.pageCopy.offering {
            if Keymap.shared.matches(event, .pageCopyMarkdown) { browser.copyPageMarkdown(); return true }
            if Keymap.shared.matches(event, .pageCopyFile) {
                if browser.pageCopy.canSave { browser.savePageForAgent() }
                return true
            }
            if only == .command, key == "c",
               Keymap.shared.systemBrowserAction(for: event) == nil {
                DispatchQueue.main.async { browser.pageCopy.did(.copy) }
                return false
            }
            if event.keyCode == 53, only.isEmpty { browser.pageCopy.dismiss(); return true }
            if !(only == .command && key == "a") { browser.pageCopy.dismiss() }
        }
        // After the page has had ⌘A and done its selecting.
        if only == .command, key == "a",
           Keymap.shared.systemBrowserAction(for: event) == nil,
           let tab = browser.active, !tab.typing, !browser.fieldShowing,
           let web = tab.builtPage, (event.window?.firstResponder as? NSView)?.isDescendant(of: web) == true {
            DispatchQueue.main.async { browser.offerPageCopy() }
        }

        // Return is the walk-through's button, on every step of it.
        if browser.welcoming, [36, 76].contains(event.keyCode),
           flags.intersection([.command, .option, .control, .shift]).isEmpty,
           let press = browser.welcomeReturn {
            press()
            return true
        }
        if browser.welcoming, Keymap.shared.matches(event, .welcomeBack), let back = browser.welcomeBack {
            back()
            return true
        }
        // Esc goes back in it too, as ⌘[ does.
        if browser.welcoming, event.keyCode == 53, flags.intersection([.command, .option, .control, .shift]).isEmpty,
           let back = browser.welcomeBack {
            back()
            return true
        }

        // ⌥↩ in a form fills it all (FormFill), with the list up or not;
        // ⌘Z right after puts it back, until something is typed.
        if Keymap.shared.matches(event, .fillForm), browser.fillFormHere() {
            return true
        }
        if key == "z", flags.intersection([.command, .option, .control, .shift]) == [.command],
           Keymap.shared.systemBrowserAction(for: event) == nil,
           !browser.fieldShowing, event.window?.firstResponder is any PageHandle, browser.undoFormFill() {
            return true
        }

        // The accounts hanging from a sign-in box answer to the arrows like
        // any list that drops from a field; Return takes the lit one, and
        // with none lit is left to the page, to send the form. Only while
        // their page is the one in front and the field isn't up: a list left
        // hanging in a tab of another space never takes the field's keys.
        if let peek = browser.peeking, !browser.editing, browser.autofillKey(event, on: peek) { return true }
        let lists = browser.editing ? nil : browser.active?.id
        if let asked = browser.suggesting, asked.tab == lists, only.isEmpty {
            switch event.keyCode {
            case 125: browser.moveChoice(1); return true
            case 126: browser.moveChoice(-1); return true
            case 36, 76: if browser.chooseLit() { return true }
            default: break
            }
        } else if let list = browser.codeList, list.tab == lists, only.isEmpty {
            // The codes under a box that asks for one, the same way.
            switch event.keyCode {
            case 125: browser.moveCode(1); return true
            case 126: browser.moveCode(-1); return true
            case 36, 76: if browser.pickLitCode() { return true }
            default: break
            }
        } else if let list = browser.walletList, list.tab == lists, only.isEmpty {
            // The cards or addresses under a box, the same way.
            switch event.keyCode {
            case 125: browser.moveWallet(1); return true
            case 126: browser.moveWallet(-1); return true
            case 36, 76: if browser.chooseWalletLit() { return true }
            default: break
            }
        } else if PageSnippets.shared.key(event, browser: browser) {
            // The snippets under ";" and a name: ⇥ takes one too, and esc
            // leaves what was typed (PageSnippets).
            return true
        }
        // Words pasted often, offered as a snippet: ↩ Save, esc Not Now.
        if SnippetOffers.shared.key(event, browser: browser) { return true }

        // What an agent asks at the page's foot takes the same keys, the
        // same way: Return for its yes or Done, ⌘Return for a yes that
        // can't be taken back, Escape for Not now, from the page, and never
        // while the caret is in something typed into.
        if ([36, 76, 53].contains(event.keyCode) || Keymap.shared.matches(event, .confirmDanger)
            || [125, 126].contains(event.keyCode) && browser.active.flatMap { Payments.shared.flow($0) }?.model.pane.isList == true),
           let tab = browser.active, !tab.typing,
           let web = tab.builtPage, (event.window?.firstResponder as? NSView)?.isDescendant(of: web) == true,
           Agents.shared.keyed(tab, event: event) {
            return true
        }
        // The same card in a chat's field, in the field's place: its keys
        // come from anywhere in the window nothing is typed into.
        if ([36, 76, 53].contains(event.keyCode) || Keymap.shared.matches(event, .confirmDanger)),
           browser.chatOpen, !browser.fieldShowing, browser.peeking == nil, browser.active?.typing != true,
           !(event.window?.firstResponder is NSText),
           let chat = Chats.shared.chat(Agents.shared.columnChat),
           let tab = ChatColumn.asking(chat, browser: browser), tab.choices.isEmpty,
           Agents.shared.keyed(tab, event: event) {
            return true
        }
        // A question for the whole chat there (Agents.askChat): Return its
        // yes, Escape Not Now, on the same terms.
        if [36, 76, 53].contains(event.keyCode), flags.intersection([.command, .option, .control, .shift]).isEmpty,
           browser.chatOpen, !browser.fieldShowing, browser.peeking == nil, browser.active?.typing != true,
           !(event.window?.firstResponder is NSText),
           let id = Agents.shared.columnChat, let permit = Agents.shared.session(id)?.permit,
           Chats.shared.chat(id).flatMap({ ChatColumn.asking($0, browser: browser) }) == nil {
            Agents.shared.answer(chat: id, yes: event.keyCode != 53, key: permit.key)
            return true
        }
        // ⌘Z for the Undo toast of a mail on its way (AskStand), on the
        // same terms; the page keeps ⌘Z whenever no such toast is up.
        if event.keyCode == 6, flags.intersection([.command, .option, .control, .shift]) == .command,
           !AskStand.shared.toasts.isEmpty, !browser.fieldShowing, browser.active?.typing != true,
           !(event.window?.firstResponder is NSText), AskStand.shared.undoLast() {
            return true
        }
        // The question in the window's corner (AgentAskCorner), on the
        // same terms: never while the caret is in something typed into.
        if ([36, 76, 53].contains(event.keyCode) || Keymap.shared.matches(event, .confirmDanger)),
           !browser.fieldShowing, browser.peeking == nil, browser.active?.typing != true,
           !(event.window?.firstResponder is NSText),
           Agents.shared.cornerKeyed(event, in: browser) {
            return true
        }
        // Escape with the keys in the chat's column, on nothing typed into:
        // the column away (register 1130). The empty field's own Escape
        // does the same (ChatComposer); a page's Escape stays the page's.
        if event.keyCode == 53, flags.intersection([.command, .option, .control, .shift]).isEmpty,
           browser.chatOpen, !browser.fieldShowing, browser.peeking == nil,
           !(event.window?.firstResponder is NSText), let column = browser.chatColumnView,
           (event.window?.firstResponder as? NSView)?.isDescendant(of: column) == true {
            if !event.isARepeat { browser.hideChat() }
            return true
        }

        // The password pill takes Return and Escape, Save, and Not now,
        // but only from the page, and only while the caret isn't somewhere
        // on it that takes typing: there Return is the page's, to send what
        // was typed. Its own name box keeps Return; Escape leaves the box.
        if flags.intersection([.command, .option, .control, .shift]).isEmpty,
           [36, 76, 53].contains(event.keyCode),
           let tab = browser.active, let offer = tab.offer, !offer.parked {
            let escape = event.keyCode == 53
            if offer.stage == .naming {
                if escape { browser.unnameOffer(tab); return true }
            } else if !tab.typing, let web = tab.builtPage, (event.window?.firstResponder as? NSView)?.isDescendant(of: web) == true {
                switch (offer.stage, escape) {
                case (.asking, false), (.refused, false): browser.keepOffer(tab); return true
                case (.asking, true): browser.parkOffer(tab); return true
                case (.refused, true), (.never, true): browser.dismissOffer(tab); return true
                default: break
                }
            }
        }

        // A boost on trial: ⌘↩ keeps it (⌥⌘↩ for every site, where it may),
        // Escape undoes it, from the page and never while typing into it.
        if let tab = browser.active, let trial = Boosts.shared.trials[tab.id], !tab.typing,
           let web = tab.builtPage, (event.window?.firstResponder as? NSView)?.isDescendant(of: web) == true {
            let rest = flags.intersection([.command, .option, .control, .shift])
            if [36, 76].contains(event.keyCode), rest == .command || rest == [.command, .option] {
                guard trial.ready, trial.problem == nil else { return true }
                let everywhere = rest.contains(.option) && trial.package.canApplyEverywhere && !trial.package.allSites
                Task { await Boosts.shared.keep(trial.id, on: tab, everywhere: everywhere) }
                return true
            }
            if event.keyCode == 53, rest.isEmpty {
                Task { await Boosts.shared.undo(on: tab) }
                return true
            }
        }

        // A userscript's Keep card: ⌘↩ keeps it, Escape closes it.
        if Userscripts.shared.key(event, browser: browser) { return true }

        // A card or an address to keep takes them the same way.
        if flags.intersection([.command, .option, .control, .shift]).isEmpty,
           [36, 76, 53].contains(event.keyCode),
           let tab = browser.active, tab.offer == nil, let pay = tab.payOffer, !pay.parked,
           !tab.typing, let web = tab.builtPage, (event.window?.firstResponder as? NSView)?.isDescendant(of: web) == true {
            if event.keyCode == 53 {
                pay.refused ? browser.dismissPay(tab) : browser.parkPay(tab)
            } else {
                browser.keepPay(tab)
            }
            return true
        }

        // A peek open over the page: Escape and ⌘W put it away, ⌘O keeps it.
        // As they are now: Settings › Shortcuts or App Shortcuts can give
        // each other keys (Hotkeys). Close Peek given another, Escape goes
        // on below, and to the page in the peek.
        if let page = browser.peeking, !browser.fieldShowing {
            // Escape puts the peek's find bar away first, as in Arc.
            if event.keyCode == 53, flags.intersection([.command, .option, .control, .shift]).isEmpty, page.finder.shown {
                page.finder.close()
                return true
            }
            let hotkeys = Hotkeys.shared
            if hotkeys.matches(event, "Close Peek") || Keymap.shared.matches(event, .closeTab) { browser.closePeek(); return true }
            if hotkeys.matches(event, "Open Peek as Tab") { browser.keepPeek(); return true }
            if hotkeys.matches(event, "Open Peek in Split View") { browser.splitPeek(); return true }
        }

        // Escape puts the page back. On an empty private tab there is no page
        // to put back, so it belongs to whatever else wants it.
        if event.keyCode == 53, flags.intersection([.command, .option, .control, .shift]).isEmpty {
            if browser.editingTab != nil {
                browser.cancelTabEdit()
                return true
            }
            if browser.suggesting != nil {
                browser.dropChoice()
                return true
            }
            if browser.walletList != nil {
                browser.dropWallet()
                return true
            }
            if browser.veiling {
                browser.toggleHiding()
                return true
            }
            if browser.finding {
                browser.closeFind()
                return true
            }
            // One step at a time: ⌘K's list, the field's own place, the
            // list, then the field.
            // Rows picked together are put down first, the chosen one kept.
            if browser.fieldShowing, browser.unpickRows() { return true }
            if browser.fieldShowing, browser.leavePlace() { return true }
            // Out of the compact card's Actions, to its list.
            if browser.fieldShowing, browser.leaveActions() { return true }
            if browser.unchoose() { return true }
            // Then the site the field was searching: a plain field again,
            // what was typed kept.
            if browser.leaveScope() { return true }
            // Then Private, while its tab has nothing in it: the plain field.
            if browser.fieldShowing, browser.leavePrivate() { return true }
            // Tabs picked alongside the open one are put down before the
            // key goes on to the page.
            if browser.unpick() { return true }
            // Then the page's address, if it was typed over; then the field.
            if browser.restore() { return true }
            // No tab in front: the tab ⌘W closed back, the space you came
            // from, or, on the window's own ground, the words typed gone.
            if browser.active == nil {
                browser.dismiss()
                return true
            }
            guard browser.editing, browser.active?.isBlank == false else { return false }
            browser.dismiss()
            return true
        }

        // The field's own keys, ahead of the menus that have the same ones
        // (⌘P prints, ⇧⌘P floats a video): ⌘K lists what can be done to
        // the chosen row, and in Clipboard History the history's own.
        if browser.fieldShowing, let editor = event.window?.firstResponder as? NSTextView, editor.isFieldEditor,
           (editor.delegate as? NSTextField)?.delegate is AddressField.Coordinator || browser.query.acting != nil {
            let map = Keymap.shared
            // An answer's own first: ⌘↩ there is a task, not a tab ahead.
            if browser.answerKey(event) { return true }
            // ⌘↩ on a row of Now is its Do It, as ⌥↩ is its Later.
            if map.matches(event, .fieldCopy) {
                if browser.hintKey("hand") { return true }
                // In Now's own place too, filtered or not: its words only filter.
                if browser.query.place == .now, browser.query.acting == nil, browser.runAction("hand") { return true }
                browser.submit(.behind)
                return true
            }
            if map.matches(event, .fieldAhead) { browser.submit(.ahead); return true }
            if map.matches(event, .fieldAlternate) {
                if browser.hintKey("later") { return true }
                browser.submitAlternate()
                return true
            }
            if map.matches(event, .fieldDone), browser.hintKey("done") { return true }
            if map.matches(event, .fieldDo), browser.hintKey("hand") { return true }
            // ⌘C on a mail's code in Now, nothing typed to copy instead.
            if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
               event.charactersIgnoringModifiers == "c", editor.selectedRange().length == 0,
               browser.hintKey("copy") { return true }
            if map.matches(event, .fieldForget), browser.forgetChosen() { return true }
            if browser.fieldKey(event) { return true }
        }

        // Tab is the page's, as in every browser: it moves through the
        // page's links, buttons and boxes. The tabs are ⌃Tab's, the
        // recent-tab walk, and ⇧⌘[ ⇧⌘]'s.
        //
        // In the field Tab walks the list under it and comes round to the
        // first again, ⇧Tab the other way, and Return takes whatever the
        // walk landed on.
        if event.keyCode == 48, flags.isDisjoint(with: [.command, .option, .control]) {
            if browser.editingTab != nil { return true }
            // A row being written in a place: Tab goes from field to field.
            if browser.query.edit != nil { return false }
            guard browser.fieldShowing else { return false }
            // A site the words name: Tab searches it (see Scopes), ahead of
            // finishing its address, which is what the site's name was for.
            // Other words: Tab asks the agent them at once (askOnTab).
            if !flags.contains(.shift), browser.picked == nil,
               browser.query.pointed == nil && (browser.enterNamedPlace() || browser.enterScope()) || browser.askOnTab() {
                return true
            }
            // The compact card's empty field: Tab opens its Actions, as Arc's.
            if !flags.contains(.shift), browser.enterActions() { return true }
            // The gray ending, with no row walked to or pointed at: Tab takes
            // it, as everywhere else a field finishes a word (see AddressField).
            if !flags.contains(.shift), browser.ending?.isEmpty == false,
               browser.picked == nil, browser.query.pointed == nil {
                return false
            }
            if !browser.offers.isEmpty {
                browser.walk(flags.contains(.shift) ? -1 : 1)
                return true
            }
            browser.step(flags.contains(.shift) ? -1 : 1)
            return true
        }

        // A finished chat's Done from anywhere in the window, as the card
        // at a page's foot takes it: not while something else is typed
        // into, the page's boxes or ours, nor over the field or a peek,
        // which have ⌘↩ of their own (above). Selecting read-only text
        // leaves Done available; only an editable text responder owns it.
        if browser.chatOpen, !browser.chatAttach.typing, !browser.fieldShowing, browser.peeking == nil,
           browser.active?.typing != true, !Self.textResponderOwnsDone(event.window?.firstResponder),
           let chat = browser.chatAttach.finishableChatID {
            if Keymap.shared.matches(event, .chatDoneKeep) {
                Agents.shared.finish(chat, in: browser, keepingTabs: true)
                return true
            }
            if Keymap.shared.matches(event, .chatDone) {
                Agents.shared.finish(chat, in: browser, keepingTabs: false)
                return true
            }
        }

        // Extension keys use the same ownership check here and at the bench.
        // Recording one through Keymap.clash frees Yab's binding first.
        // A Chromium tab's are the keys Chrome gave its extensions' commands.
        if ChromiumExtensionCommands.take(event, in: browser) { return true }
        if #available(macOS 15.4, *), Extensions.of(browser).take(event) {
            return true
        }

        // ⌘Z outside text: the last thing done in the window, taken back
        // (WindowUndo.swift). A page that keeps ⌘Z for itself, a canvas or
        // Get to Know, has it first; one it sends back is the window's.
        if flags.contains(.command), !flags.contains(.shift), !flags.contains(.option), !flags.contains(.control),
           key == "z", !browser.veiling {
            let editor = event.window?.firstResponder as? NSTextView
            // The chat's box, empty and with nothing of its own to undo.
            let emptyChat = browser.chatAttach.typing && editor.map { $0.string.isEmpty && $0.undoManager?.canUndo != true } == true
            let native = !emptyChat && editor.map {
                !($0.isFieldEditor && $0.string.isEmpty && browser.fieldShowing
                  && ($0.delegate as? NSTextField)?.delegate is AddressField.Coordinator)
            } ?? false
            if browser.canUndoClose(nativeEditor: native, emptyEditor: emptyChat) {
                if pageFirst(event, reserved: false) { return false }
                browser.undoWindow()
                return true
            }
        }

        // The keys chosen in Settings › Shortcuts, the ones it comes with
        // unless changed, looked up by what the ASCII layout calls the key.
        // A page has the first turn at one it may want for itself, unless
        // it is one yab keeps first (see `pageFirst`).
        // An F key alone is a shortcut too: nothing is typed with it.
        let chord = !flags.intersection([.command, .option, .control]).isEmpty
            || KeyLayout.named[event.keyCode].map { Hotkey($0, []).isFunctionKey } == true
        if chord, let command = Keymap.shared.command(for: event) {
            guard CommandHotkeys.available(command, in: browser) != nil else { return false }
            if pageFirst(event, reserved: false) { return false }
            return Keymap.shared.run(command, in: browser)
        }
        if chord, let action = Keymap.shared.action(for: event)?.action {
            // F12 is the page's first (Shortcut.also).
            let reserved = Shortcut.reservesPageKey(action, readAs: Hotkey(event))
            if pageFirst(event, reserved: reserved) { return false }
            return perform(action, event)
        }
        if chord, let action = Hotkey.first(event, { QuickActions.shared.action(for: $0) })?.1 {
            if pageFirst(event, reserved: false) { return false }
            browser.run(action)
            return true
        }

        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return false }
        let shifted = flags.contains(.shift)

        if key == "i", !shifted, browser.active?.typing != true,
           !(event.window?.firstResponder is NSTextView),
           let id = browser.folderBook.focused,
           browser.nests.contains(where: { $0.id == id }) {
            IconPicking.shared.open(.nest(id))
            return true
        }

        // The page's turn first, for the keys it may want for itself. ⌘.
        // stays yab's, for an agent's tab, and ⌘Z while pointing at what
        // to hide.
        if pageFirst(event, reserved: key == "." || (key == "z" && browser.veiling)) { return false }

        return commands(event, key: key, shifted: shifted)
    }

    /// yab's own ⌘ keys, as the page left them: after `pageFirst`, or on
    /// a key's way back from a page that had no use for it. The chosen
    /// ones first, then the few that are only yab's in some places.
    private func commands(_ event: NSEvent, key: String, shifted: Bool) -> Bool {
        if let command = Keymap.shared.command(for: event) {
            return Keymap.shared.run(command, in: browser)
        }
        if let action = Keymap.shared.action(for: event)?.action {
            return perform(action, event)
        }
        // A key moved away from an action is nobody's now, not the action
        // beside it with Shift's, nor AppKit's File › Close (Keymap.nobodys).
        if Keymap.shared.nobodys(event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return false }
        switch key {
        case "z" where !shifted:
            // While pointing, the hiding. A ⌘Z the page had first and sent
            // back unused is the window's, as the ⌘Z in the key monitor
            // promises: until then nothing took it, and a bookmark deleted
            // from the bar's menu with the page in front never came back
            // (feedback #153).
            if browser.veiling {
                browser.undoHiding()
            } else if (event.window?.firstResponder is PageView || event.window?.firstResponder is ChromiumPage),
                      browser.canUndoClose(nativeEditor: false) {
                browser.undoWindow()
            } else {
                return false
            }
        default:
            // Moving the caret, or selecting with ⇧, belongs to the text,
            // not to the page's history: in a page's fields and in yab's own.
            guard !shifted, browser.active?.typing != true,
                  !(event.window?.firstResponder is NSTextView)
            else { return false }
            return false
        }
        return true
    }

    /// What a shortcut does, from the key monitor. False leaves the key to
    /// whatever else wants it: ⌃1 while there are no spaces. Not ⌘S, which
    /// always has something to put away, the column or the strip: given up
    /// with the tabs across the top, it went on to the menu and put the tabs
    /// down the side (#48).
    private func perform(_ action: Shortcut.Action, _ event: NSEvent) -> Bool {
        switch action {
        case .newWindow: browser.newWindow()
        case .blankWindow: browser.newBlankWindow()
        case .closeWindow: BrowserWindows.shared.window(for: browser)?.performClose(nil)
        case .newTab: browser.pressNewTab()
        case .newTabInFolder:
            guard let nest = browser.folderHere else { return false }
            browser.newTab(in: nest)
        case .privateTab: browser.newPrivateWindow()
        case .closeTab:
            if !browser.cancelInstantSearch() { browser.shut(browser.chosen, byKey: true) }
        case .reopen: browser.reopen()
        case .nextTab: browser.step(1)
        case .previousTab: browser.step(-1)
        case .recentTab, .recentTabReverse:
            guard browser.editingTab == nil, !browser.welcoming else { return false }
            browser.switchStep(action == .recentTab ? 1 : -1)
            if Keymap.shared.keys(action)?.flags.isEmpty == true { browser.landSwitch() }
        // ⌘← and ⌘→ move the caret in anything being typed into, a page's
        // box or yab's own field; only outside text are they the way back.
        case .backArrow, .forwardArrow:
            if browser.active?.typing == true || browser.active?.webKitOnly("Native editable input context", build: false)?.inputContext != nil
                || event.window?.firstResponder is NSTextView { return false }
            action == .backArrow ? browser.back(byKey: true) : browser.forward(byKey: true)
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            let number = Int(action.rawValue.dropFirst(3)) ?? 1
            browser.select(index: number == 9 ? browser.tabs.count - 1 : number - 1)
        case .space1, .space2, .space3, .space4, .space5, .space6, .space7, .space8, .space9:
            guard browser.turnsSpaces else { return false }
            browser.switchSpace(index: (Int(action.rawValue.dropFirst(5)) ?? 1) - 1)
        case .sendSpace1, .sendSpace2, .sendSpace3, .sendSpace4, .sendSpace5, .sendSpace6, .sendSpace7, .sendSpace8, .sendSpace9:
            guard browser.spacesShown else { return false }
            // Counted as ⌃1 to ⌃9 count, Mail in its place; no tab goes to Mail.
            let index = (Int(action.rawValue.dropFirst(9)) ?? 1) - 1
            let order = browser.turnOrder
            if order.indices.contains(index), order[index].id != Space.mailID, !browser.chosen.isEmpty {
                browser.moveTabs(browser.chosen, to: order[index].id)
            }
        case .newSmallWindow:
            guard browser.prefs.smallKey else { return false }
            LinkWindow.blank()
        // Heard from every app by its hot key, before any window sees it.
        case .showYab: return false
        case .smallSpace, .spaceDelete, .fieldActions, .fieldFilter, .fieldPin, .fieldPage, .fieldSecond, .fieldReveal,
             .fieldCode, .fieldShow, .fieldEdit, .fieldNew, .fieldDelete, .fieldClear,
             .fieldCopy, .fieldAlternate, .fieldAhead, .fieldMove, .fieldForget, .fieldDone, .fieldAbout, .fieldDo,
             .fieldFavorite, .fieldFavoriteUp, .fieldFavoriteDown,
             .answerSend, .answerRewrite, .answerInsert, .answerCopy, .answerAsk,
             .answerPick1, .answerPick2, .answerPick3, .callMic, .callCamera, .callShare,
             .agentTakeWheel, .agentHandBack, .agentStop, .agentAsk,
             .agentChoice1, .agentChoice2, .agentChoice3, .agentChoice4, .agentChoice5,
             .agentChoice6, .agentChoice7, .agentChoice8, .agentChoice9,
             .feedbackSend, .welcomeBack, .confirmDanger, .pageCopyMarkdown, .pageCopyFile,
             .mailCommands, .mailAccountAll, .mailAccount1, .mailAccount2, .mailAccount3, .mailAccount4,
             .mailAccount5, .mailAccount6, .mailAccount7, .mailAccount8, .mailAccount9,
             .mailCopyChip, .mailRewrite, .mailSend, .mailSendLater, .mailBack, .mailForward,
             .mailNew, .mailOpen, .mailNext, .mailPrevious, .mailReply, .mailDone, .mailRemind,
             .mailDoIt, .mailKeep, .mailUnread, .mailWake, .mailSearch, .mailUndo, .mailUndoCommand,
             .mailPick1, .mailPick2, .mailPick3, .mailWriteDraft,
             .mailStar, .mailTrash, .mailSpam, .mailMute, .mailNotDone,
             .mailSelect, .mailSelectDown, .mailSelectUp, .mailSelectBelow, .mailSelectAll,
             .mailOnlyUnread, .mailOnlyStarred, .mailOnlyUnanswered, .mailKeys,
             .mailReplyAll, .mailForwardMail, .mailBcc, .mailSubject, .mailOpenFile, .mailSaveFile, .mailRemindNoReply,
             .mailUnsubscribe, .mailBlock, .mailZero, .mailBulk, .mailAttach,
             .mailLabel, .mailMove, .mailUnlabel, .mailSummarize, .mailVIP,
             .mailFrom, .mailBold, .mailItalic, .mailUnderline, .mailBullets, .mailNumbers, .mailQuote, .mailSnippet,
             .mailAccept, .mailMaybe, .mailDecline, .mailSlots,
             .fieldAnswerAgain, .fieldAnswerModel, .fieldAnswerCopy, .fieldAnswerTask,
             .selectionCopy, .selectionRetry, .captureSave, .captureWhole,
             .chatDone, .chatDoneKeep: return false
        // With several tabs picked, what is about a tab is about all of them;
        // what is about a page, reload, find, zoom, stays with the open one.
        case .duplicate: browser.several ? browser.duplicate(browser.chosen) : browser.duplicate()
        case .pin: browser.togglePin()
        case .rename:
            guard !browser.several else { return false }
            browser.renameActive()
        case .split:
            if browser.pair(of: browser.activeID) != nil { browser.separate() } else { browser.splitView() }
        case .moveLeft: browser.nudge(-1)
        case .moveRight: browser.nudge(1)
        case .moveToWindow:
            guard let tab = browser.active else { return false }
            BrowserWindows.shared.moveToNewWindow(tab, from: browser)
        case .pickAll: browser.pickAll()
        case .closeOthers: browser.closeOthers(but: browser.chosen)
        case .closeBefore: browser.closeBefore()
        case .closeAfter: browser.closeAfter()
        case .nextSpace, .previousSpace:
            guard browser.turnsSpaces else { return false }
            browser.stepSpace(action == .nextSpace ? 1 : -1)
        case .mute: browser.toggleMute(browser.several ? browser.chosen : nil)
        case .openAddress: browser.pressOpenAddress()
        case .copyAddress: browser.several ? browser.copyAddresses(browser.chosen) : browser.copyAddress()
        case .copyMarkdownLink: browser.copyMarkdownLink(browser.several ? browser.chosen : nil)
        case .sharePage: return browser.sharePage()
        case .pasteAndMatchStyle:
            guard let key = Keymap.shared.keys(.pasteAndMatchStyle), PasteStyleMenuOrder.permits(key, in: NSApp.mainMenu) else { return false }
            return PasteStyleTarget.current(in: event.window).perform()
        case .pasteAndGo:
            // In a text field ⇧⌘V is paste without formatting, as in
            // Chrome: a Google Doc, a form, the address field. It means Paste
            // and Go only when nothing is being typed. WebKit has no use for
            // ⌘⇧V and would hand it back to the menu's Paste and Go, so the
            // plain paste is done here. A web view has an input context only
            // while the caret is in something editable, in any frame, those
            // the page's own script can't look into included.
            if browser.active?.typing == true || browser.active?.webKitOnly("Native editable input context", build: false)?.inputContext != nil
                || browser.editing || event.window?.firstResponder is NSTextView {
                _ = event.window?.firstResponder?.tryToPerform(#selector(NSTextView.pasteAsPlainText(_:)), with: nil)
            } else {
                browser.pasteAndGo()
            }
        case .keepTab: browser.toggleKeepTabs()
        case .folderWithTabs:
            guard browser.chosen.contains(where: \.keepable) else { return false }
            browser.newFolder(picked: browser.chosen)
        case .bookmark: browser.several ? browser.keep(browser.chosen) : browser.bookmarkCurrent()
        case .back: browser.back(byKey: true)
        case .forward: browser.forward(byKey: true)
        case .reload: browser.reload()
        case .stopLoading:
            guard let tab = browser.active, tab.loading else { return false }
            browser.stop(tab)
        case .hardReload: browser.hardReload()
        case .find: browser.openFind()
        case .findNext: browser.look(forward: true)
        case .findPrevious: browser.look(forward: false)
        case .reader: browser.toggleReader()
        case .translatePage: return browser.toggleTranslation()
        // Only where pages can be dark and no extension has the key first;
        // anywhere else the key is the page's, as it was.
        case .darkPage:
            guard !DarkPages.extensionHolds(event) else { return false }
            return browser.toggleDarkPage()
        case .float: browser.toggleFloat()
        case .fillForm: return browser.fillFormHere()
        case .hide: browser.toggleHiding()
        case .zoomIn: browser.zoom(by: 1.1)
        case .zoomOut: browser.zoom(by: 1 / 1.1)
        case .actualSize: browser.resetZoom()
        case .print: browser.printPage()
        case .inspector: browser.developerTools()
        case .console: browser.showConsole()
        case .inspectElement: browser.inspectElement()
        case .devMode:
            // Control-D still deletes forward while someone is editing text.
            guard browser.active?.typing != true, !(event.window?.firstResponder is NSTextView) else { return false }
            if !event.isARepeat { return browser.toggleDevMode() }
            return browser.canToggleDevMode
        case .devSheet: browser.toggleDevSheet()
        // Only on a page that came as JSON; the key is the page's elsewhere.
        case .jsonView:
            guard browser.jsonFront != nil else { return false }
            browser.toggleJSON()
        // Rulers are for a page being made, on this Mac's own server; on
        // any other the key is the page's.
        case .measure:
            guard browser.devFront != nil else { return false }
            browser.toggleMeasure()
        case .capture:
            guard browser.active?.isBlank == false else { return false }
            browser.capture.start()
        // Only while a peek is open (LinkPeek.swift); the key is the page's
        // otherwise.
        case .peekTab:
            guard browser.peeking != nil else { return false }
            browser.keepPeek()
        case .peekSplit:
            guard browser.peeking != nil else { return false }
            browser.splitPeek()
        case .peekClose:
            guard browser.peeking != nil else { return false }
            browser.closePeek()
        case .sidebarTabs: browser.toggleSidebar()
        case .closeChat:
            if !event.isARepeat { browser.toggleChat() }
        // The chat in the column, into a project (ChatMoves).
        case .moveToProject:
            guard browser.chatOpen, !browser.chatHistory, Chats.shared.chat(browser.chatID) != nil else { return false }
            ChatMoves.ask(in: browser)
        // Puts the column away and brings it back, or with the tabs across
        // the top, the strip.
        // On a page that came as JSON, ⌘S is Save JSON… (JSONView.swift).
        case .column:
            if browser.jsonFront?.json.map({ $0.shown != .sent }) == true {
                browser.saveJSON()
            } else {
                // A held shortcut is one sidebar command. Consume repeats
                // here, including remapped keys, before they reverse the
                // current transition. The horizontal strip keeps its route.
                if browser.prefs.sidebar, event.isARepeat { return true }
                browser.toggleColumn()
            }
        case .bookmarksBar: browser.toggleBookmarkBar()
        case .addressBar: browser.prefs.addressBar.toggle()
        case .extensions: browser.toggleExtensions()
        // Straight into the box's place; the same key in it, its page.
        case .history: browser.openPlace(.history)
        case .downloads: browser.openPlace(.downloads)
        case .bookmarks: browser.showBookmarks()
        case .passwords: browser.openPlace(.passwords)
        case .snippets: browser.openPlace(.snippets)
        case .clipboard, .emoji, .autofill, .chats, .routines, .boostStore, .now, .purchases:
            return browser.openPlace(shortcut: action)
        case .settings: browser.tuning = true
        // On the window in front, as the Help menu's item (FeedbackSheet.show).
        case .sendFeedback: Links.writeFeedback()
        // Mail's space and back, once an account is in (MailSpace).
        case .mail:
            guard MailCenter.shared.connected || browser.inMail else { return false }
            browser.toggleMail()
        // With no call on, the key is the page's.
        case .muteCall:
            guard browser.call != nil else { return false }
            browser.toggleCallMic()
        case .joinMeeting: browser.joinNextMeeting()
        // With nothing open with a meeting's people, the key is the page's.
        case .openMeetingThread: return browser.openMeetingThread()
        }
        return true
    }
}

/// The History menu's Recently Visited, watching the history itself: a page
/// visited redraws this menu and nothing else. The browser passed every
/// change of the history on as its own for this menu, and every view of
/// every window that watches the browser, the column and the strip among
/// them, was drawn again at each page loaded, twice.
struct RecentlyVisited: View {
    let history: History
    let browser: Browser

    var body: some View {
        if Narrow.menu { Listed(recent: RecentMenu.following(history), browser: browser) } else { Live(history: history, browser: browser) }
    }

    /// The places a moment after the history changes (RecentMenu).
    private struct Listed: View {
        @ObservedObject var recent: RecentMenu
        let browser: Browser
        var body: some View { RecentlyVisited.section(recent.visited, browser) }
    }

    private struct Live: View {
        @ObservedObject var history: History
        let browser: Browser
        var body: some View { RecentlyVisited.section(history.recent(), browser) }
    }

    @ViewBuilder
    static func section(_ visited: [History.Trace], _ browser: Browser) -> some View {
        Section("Recently Visited") {
            if visited.isEmpty {
                Button("Nothing visited yet") {}
                    .disabled(true)
            }
            ForEach(visited) { trace in
                Button {
                    browser.open(trace.url, foreground: true)
                } label: {
                    MenuLine(title: trace.title.isEmpty ? trace.key : trace.title, url: trace.url)
                }
            }
        }
    }
}

/// The page's card with nothing on it (an empty space on a backdrop): a
/// window onto what is behind the window, blurred, as Arc's empty card
/// shows the desktop through even an opaque space, the space's look over
/// it at 0.7, picked from three strengths on the user's own screen. The
/// look as the window wears it: its colors' gradient when it has colors,
/// not the one color picked by hand before them (a pink, brown in dark,
/// under a blue-green window).
private struct EmptyCard: View {
    let corner: CGFloat
    let dark: Bool
    let tint: NSColor
    /// The look's colors after `tint`, as WindowBackdrop's gradient lays
    /// them, top leading to bottom trailing; none for a plain color.
    let colors: [NSColor]

    var body: some View {
        let card = RoundedRectangle(cornerRadius: corner, style: .continuous)
        BehindWindow(corner: corner, dark: dark)
            .overlay {
                if colors.isEmpty {
                    card.fill(Color(nsColor: tint).opacity(0.7))
                } else {
                    card.fill(LinearGradient(colors: ([tint] + colors).map { Color(nsColor: $0) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .opacity(0.7)
                }
            }
            // Light, the color mostly washed out, as Arc's empty card on
            // the same look: its sidebar's mint taken some 70% toward
            // white (measured 212,250,230 → 241,253,249), still see-through.
            .overlay { if !dark { card.fill(Color.white.opacity(0.75)) } }
            .overlay { card.strokeBorder(Palette.ink.opacity(0.06), lineWidth: 1) }
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// AppKit's blur of what lies behind the window, cut to a rounded card.
private struct BehindWindow: NSViewRepresentable {
    let corner: CGFloat
    let dark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.layer?.cornerRadius = corner
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }
}
