import AppKit
import SwiftUI

// Settings' own pages, General to About: each its own view, watching only
// what it shows, so an update's progress or a mail coming in draws
// that page again and not the whole pane (SettingsDetail).

/// Version and updates first, then the engine and Show Yab, app-level
/// controls, files and the steps still to do.
/// Once Yab opens the links, the default-browser step leaves the page.
struct GeneralPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: SettingsModel
    /// The welcome's browsers, kept by Settings while its window is open.
    /// Not watched here: only the default-browser steps and the row at the foot
    /// draw from it, each watching it alone, so a count coming in draws
    /// those and not the whole page.
    let bringing: Bringing
    @Binding var isDefault: Bool
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Updater.nightlyKey, store: Store.settings) private var nightly = false
    @AppStorage(Updater.Away.automaticKey, store: Store.settings) private var automatic = true

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(updater.stage == .none ? "Yab \(Updater.version)" : versionTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Text(updater.stage == .none ? SettingsWords.text("Up to date. ") + versionDetail : versionDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                versionControl
            }
            .settingsAnchor("updates")
            SettingsRow("Nightly builds", detail: "Install new builds before Stable.") {
                Toggle(SettingsWords.text("Nightly builds"), isOn: $nightly)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("nightly")
            .onChange(of: nightly) { _, on in
                if !on { Task { await offerStable() } }
            }
            SettingsRow("Update automatically", detail: "Restart Yab to install updates while your Mac is idle.") {
                Toggle("Update automatically", isOn: $automatic)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("update-automatically")
        }
        Section {
            EngineGeneralRows(model: model)
            ShortcutActionRow(does: SettingsWords.text("Show Yab"), action: .showYab,
                              slot: Keymap.shared.slot(.showYab), pill: true)
                .settingsAnchor("show-yab")
        }
        Section {
            OpenAtLoginRow()
                .settingsAnchor("open-at-login")
            ReachableRow()
                .settingsAnchor("reachable")
            SettingsRow("Warn Before Quitting") {
                Toggle(SettingsWords.text("Warn Before Quitting"), isOn: $prefs.warnsOnQuit)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("warn-quit")
        }
        Section {
            SettingsRow("Save downloads to", detail: prefs.downloads.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                Button(SettingsWords.text("Change…")) { chooseFolder() }.settingsButton()
            }
            .settingsAnchor("save-to")
            SettingsSwitch("Ask where to save each file", isOn: $prefs.asksWhereToSave).settingsAnchor("ask-where")
            SettingsSwitch("Choose files to upload in Finder", isOn: $prefs.uploadsInFinder).settingsAnchor("upload-finder")
        }
        GeneralSteps(browser: browser, bringing: bringing, model: model, isDefault: isDefault, makeDefault: makeDefault)
        BringInFoot(bringing: bringing, model: model)
    }

    private func makeDefault() {
        Links.becomeDefault { worked in
            isDefault = worked || Links.isDefault
            // The step leaves the page when it worked; only a refusal needs saying.
            if !worked { browser.announce("macOS kept your old browser", mark: "safari", on: SettingsWindow.shared.toaster) }
        }
    }

    private func chooseFolder() {
        DownloadFolder.chooseFolder(starting: prefs.downloads) { [prefs] url in prefs.downloads = url }
    }

    /// Nightly builds turned off on a build newer than Stable: nothing would
    /// change until Stable catches up, so going back is offered here, by the
    /// same checked download and swap as an update, after confirmation.
    private func offerStable() async {
        guard let stable = await updater.stableBehind(), !nightly, let window = SettingsWindow.shared.window else { return }
        let alert = NSAlert()
        alert.messageText = SettingsWords.text("Go back to Stable?")
        alert.informativeText = SettingsWords.format("You're on %@. Stable is %@, or stay here until Stable catches up.", [Updater.version, stable.version])
        alert.addButton(withTitle: SettingsWords.format("Download Stable %@", [stable.version]))
        alert.addButton(withTitle: SettingsWords.format("Stay on %@", [Updater.version]))
        alert.beginSheetModal(for: window) { answer in
            if answer == .alertFirstButtonReturn { updater.installStable(stable) }
        }
    }

    /// The version line follows the newer build from found to fetched to in
    /// place; with none, it is simply this one.
    private var versionTitle: String {
        switch updater.stage {
        // Found, but its last try to go in place failed: Check Now tries
        // again (Updater.landing).
        case .none:
            if let missed = updater.missed { return SettingsWords.format("Yab %@ is available", [missed.version]) }
            return SettingsWords.text("Yab is up to date")
        case .fetching(let next): return SettingsWords.format("Downloading Yab %@…", [next.version])
        case .ready(let next): return SettingsWords.format("Yab %@ is downloaded", [next.version])
        case .offered(let next): return SettingsWords.format("Yab %@ is available", [next.version])
        }
    }

    private var versionDetail: String {
        switch updater.stage {
        case .none:
            return updater.lastChecked.map { SettingsWords.format("Checked %@. Yab looks every hour", [$0.formatted(.relative(presentation: .named).locale(AppDates.locale))]) }
                ?? SettingsWords.text("Yab looks for a new version every hour")
        // What's new is the card's to say after the restart, with the
        // changelog; a release's notes are a paragraph, not a row's line.
        case .fetching:
            return SettingsWords.text("In the background. Your settings stay as they are")
        // A critical one doesn't wait to be opened (Updater.Away).
        case .ready(let next):
            return next.critical ? SettingsWords.text("A fix: Yab restarts for it once you are away") : SettingsWords.text("It takes over the next time Yab opens")
        case .offered:
            return SettingsWords.text("Install it from the disk image, like the first time")
        }
    }

    @ViewBuilder
    private var versionControl: some View {
        switch updater.stage {
        case .none:
            Button(SettingsWords.text(updater.checking ? "Checking…" : "Check Now")) {
                updater.check { found in
                    if found == nil { browser.announce("Yab is up to date", mark: "checkmark.circle", on: SettingsWindow.shared.toaster) }
                }
            }
            .settingsButton()
            .disabled(updater.checking)
        case .fetching:
            ProgressView().controlSize(.small)
        case .ready:
            Button(SettingsWords.text("Restart")) { updater.relaunch() }
                .settingsButton(.primary)
        case .offered(let next):
            Button(SettingsWords.text("Download")) {
                Links.openFromSettings(next.dmg, in: browser)
            }
            .settingsButton(.primary)
        }
    }
}

/// Everything that comes over from another browser, in one place,
/// since moving is done once and all at once.
struct BringInPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var model: SettingsModel
    /// Kept by Settings while its window is open.
    @Binding var bringsOpenTabs: Bool

    var body: some View {
        PageHero(page: .bringIn)
        Section {
            TabBringer(browser: browser, withOpen: $bringsOpenTabs)
            AsideBringer()
        }
        Section {
            PasswordBringer(browser: browser, anchor: "import-passwords")
            WalletBringer(browser: browser, anchor: "import-cards")
            FirefoxBringer(browser: browser, anchor: "import-firefox")
            // Exports, for a browser that isn't Chromium: Safari, Firefox.
            SettingsRow("Bring bookmarks in from a file", detail: "Import bookmarks from an HTML file.") {
                Button(SettingsWords.text("Import…")) { browser.importBookmarksFile(on: SettingsWindow.shared.toaster) }.settingsButton()
            }
            .settingsAnchor("import-bookmarks-file")
            SettingsRow("Export bookmarks to a file", detail: "Save bookmarks as an HTML file.") {
                Button(SettingsWords.text("Export…")) { browser.exportBookmarksFile(on: SettingsWindow.shared.toaster) }.settingsButton()
            }
            .settingsAnchor("export-bookmarks-file")
            SettingsRow("Bring history in from a file", detail: "Import Safari History.json or a CSV of addresses and visit times.") {
                Button(SettingsWords.text("Import…")) { browser.importHistoryFile(on: SettingsWindow.shared.toaster) }.settingsButton()
            }
            .settingsAnchor("import-history-file")
        }
        OtherHistoryRows()
        if #available(macOS 15.4, *) {
            Section {
                SettingsRow("Bring extensions in", detail: "Import extensions available in the Chrome Web Store.") {
                    Button(SettingsWords.text("Choose…")) { model.open(extension: ExtensionAdd.Step.arrival.rawValue) }.settingsButton()
                }
                .settingsAnchor("import-extensions")
            }
        }
    }
}

/// Settings › Websites: how pages look when they don't say themselves,
/// their size, fonts, dark pages and reading mode, apart from Appearance,
/// which is Yab's own window (Safari and Chrome keep the two apart too).
struct WebsitesPage: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: SettingsModel

    var body: some View {
        PageAppearanceSettings(prefs: prefs, model: model)
        SiteNotificationSettings()
    }
}

/// A line a setting: its answer across from its name, the
/// window's ways of sitting shown as pictures in their menu, and the
/// fonts, set once, behind Customize….
struct AppearancePage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: SettingsModel
    /// Window's "A color" just picked: Look opens on it, as Arc's (#459).
    @State private var lookAsked = false

    var body: some View {
        Section {
            ChoiceRow(
                title: "Theme",
                options: [("System", Look.system), ("Light", Look.light), ("Dark", Look.dark)],
                selection: $prefs.look
            )
            .settingsAnchor("theme")
            WindowMenu(prefs: prefs)
                .settingsAnchor("window")
                .onReceive(NotificationCenter.default.publisher(for: WindowMenu.lookAsked)) { note in
                    if note.object as? Preferences === prefs { lookAsked = true }
                }
            // ⌘T's two ways, a menu of pictures as Window's is.
            FieldMenu(prefs: prefs)
                .settingsAnchor("field-size")
            lookRow
            AppIconRow(model: model)
                .settingsAnchor("app-icon")
        }
        Section("Sidebar") {
            // Where the sidebar is, or that there is none: then the tabs
            // go across the top.
            ChoiceRow(
                title: "Position",
                options: [("Left", Flank.left.rawValue), ("Right", Flank.right.rawValue), ("Off", "top")],
                width: 210,
                selection: Binding(
                    get: { prefs.sidebar ? prefs.sideFlank.rawValue : "top" },
                    set: { picked in
                        withAnimation(Motion.glide) {
                            if let flank = Flank(rawValue: picked) {
                                prefs.sideFlank = flank
                                prefs.sidebar = true
                            } else {
                                // Asked for the tabs across the top: the
                                // strip, not one put away (⌘S).
                                if prefs.sidebar { prefs.stripShut = false }
                                prefs.sidebar = false
                            }
                        }
                    }
                )
            )
            .settingsAnchor("sidebar")
            SettingsSwitch("Show sidebar button", isOn: $prefs.sidebarButton)
                .settingsAnchor("sidebar-button")
            MenuRow("Tab icons", options: [("Letters", Glyph.letters), ("Site icons", Glyph.icons)], selection: $prefs.glyph)
                .settingsAnchor("tab-icons")
            MenuRow("Spaces", options: [("Emoji", false), ("Dots", true)], selection: $prefs.spaceDots)
                .settingsAnchor("space-dots")
            MenuRow("Density", options: [("Comfortable", Density.comfortable), ("Compact", Density.compact)], selection: $prefs.density)
                .settingsAnchor("density")
        }
        Section {
            MenuRow("Address bar", options: [("Hidden", AddressShow.hidden), ("Site", .site), ("Full URL", .full)],
                    selection: addressShow)
                .settingsAnchor("address-bar")
            SettingsRow("Show address bar in Peek") {
                Toggle(SettingsWords.text("Show address bar in Peek"), isOn: $prefs.peekAddress)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("peek-address")
            SettingsRow("Bookmarks bar", detail: "Show bookmarks above the page.") {
                // Through the browser, so the row comes and goes the way
                // ⇧⌘B carries it, not in one jump.
                Toggle(SettingsWords.text("Bookmarks bar"), isOn: Binding(get: { browser.bookmarkBarAsked == .always },
                                                      set: { browser.setBookmarkBar($0 ? .always : .never) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("bookmarks-bar")
            if browser.bookmarkBarAsked == .always {
                MenuRow("Bookmarks show", options: BookmarkStyle.allCases.map { (title: $0.title, value: $0) }, selection: $prefs.bookmarkStyle)
                    .settingsAnchor("bookmarks-style")
            }
        }
    }

    /// The color behind the page, or edge to edge the sidebar's: its dot,
    /// opening the look card's controls, with another browser's look to
    /// match under them. With spaces nothing here sets a look: the row
    /// takes you to Spaces, where each space's is set on its page.
    @ViewBuilder
    private var lookRow: some View {
        if spaced {
            Button { model.go(.spaces) } label: {
                SettingsRow("Look", detail: "Customize each space in Spaces.") {
                    HStack(spacing: 6) {
                        Text(SettingsWords.text("Spaces"))
                            .foregroundStyle(.secondary)
                        SettingsChevron()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // "A color" picked: the space on screen's look, at once, beside
            // where its dot would be.
            .overlay(alignment: .trailing) {
                LookPicker(paint: look(of: browser.spaceID), named: browser.space.marked(),
                           asked: $lookAsked, dotless: true)
                    .frame(width: 24, height: 24)
            }
            .accessibilityHint("Opens Spaces")
            .settingsAnchor("color")
        } else {
            SettingsRow("Look", detail: prefs.backdrop == .site ? "Used when a page has no background color."
                        : prefs.backdrop == .none ? "Sidebar color and texture, adjusted for dark mode."
                        : "Window color and texture, adjusted for dark mode.") {
                LookPicker(paint: look(of: browser.spaceID), named: browser.space.marked(), onPick: {
                    if !prefs.backdropColors.isEmpty, prefs.backdrop == .site { prefs.backdrop = .color }
                }, footer: {
                    BrowserLook(browser: browser, prefs: prefs, under: true)
                }, asked: $lookAsked)
            }
            .settingsAnchor("color")
            .task { BrowserLookFinder.shared.load() }
        }
    }

    /// A space's look: the one on screen's as the window wears it, any
    /// other's as kept; set, it is kept for the space and, on screen, worn.
    /// With no spaces, the window's own.
    private func look(of id: UUID) -> Binding<SpacePaint> {
        Binding(get: {
            id == browser.spaceID ? SpacePaint(prefs) : browser.spaces.first { $0.id == id }?.paint ?? SpacePaint(prefs)
        }, set: { paint in
            // Mail's look is its own too, kept apart from the list (MailSpaceLook).
            if id == Space.mailID || browser.spaces.contains(where: { $0.id == id }) { browser.setSpacePaint(id, to: paint) } else { paint.wear(prefs) }
        })
    }

    /// With spaces, a look is each space's own, set on its page in Spaces;
    /// with one or none, the window's, set here.
    private var spaced: Bool { prefs.usesSpaces && browser.spaces.count > 1 }

    /// The address bar and how much of the address it gives, as one menu.
    private var addressShow: Binding<AddressShow> {
        Binding(
            get: { !prefs.addressBar ? .hidden : prefs.fullURL ? .full : .site },
            set: { show in
                prefs.addressBar = show != .hidden
                if show != .hidden { prefs.fullURL = show == .full }
            }
        )
    }
}

/// General's Keep Mac Awake (AssistantReach), under Open at Login, which turning it on
/// turns on too.
struct ReachableRow: View {
    @ObservedObject private var reach = AssistantReach.shared

    var body: some View {
        SettingsRow("Keep Mac Awake", detail: "While plugged in, so tasks keep running.") {
            Toggle(SettingsWords.text("Keep Mac Awake"), isOn: $reach.on)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// Settings › Tabs, as Arc keeps it: what becomes of a tab you left (an
/// agent's too), the sites never put to sleep, ⌘-clicked links in folders
/// (Dia's switch), video coming along, the media player, your next meeting.
/// Folders from a search and tidy titles have no switch, as in Arc; Peek
/// has one, for its address along the top (PeekBand). The field's
/// suggestions are Search's.
struct TabsPage: View {
    @AppStorage(EnergySaver.key, store: Store.settings) private var energySaver = EnergySaver.off.rawValue
    @ObservedObject var prefs: Preferences
    @ObservedObject private var meetings = Meetings.shared
    @ObservedObject private var reopenKey = Keymap.shared.slot(.reopen)
    @ObservedObject private var floatKey = Keymap.shared.slot(.float)
    @ObservedObject private var meetingKey = Keymap.shared.slot(.joinMeeting)
    @ObservedObject private var recentKey = Keymap.shared.slot(.recentTab)
    /// ⌃Tab's reach as picked, empty until it is (SwitchReach.current).
    @AppStorage(SwitchReach.key, store: Store.settings) private var reach = ""
    @AppStorage(PeekClick.key, store: Store.settings) private var peekClick = PeekClick.shift.rawValue
    @AppStorage(Floater.snapToEdgesKey, store: Store.settings) private var snapPiPToEdges = true

    var body: some View {
        Section {
            SettingsRow("Close tabs you haven't opened in", detail: reopenKey.keys.map { "Pinned and kept tabs stay open. Reopen closed tabs with \($0.settingsHint)." } ?? "Pinned and kept tabs stay open. Reopen closed tabs from the Tabs menu.") {
                DropMenu("Close tabs you haven't opened in", options: Tidy.allCases.map { (title: $0.title, value: $0) },
                         selection: $prefs.tidyAfter)
                    .fixedSize()
            }
            .settingsAnchor("tidy")
            SettingsRow("Peek links with", detail: "Option-click opens Peek instead of Split View in regular tabs.") {
                DropMenu("Peek links with", options: [(title: SettingsWords.text("Shift-click"), value: PeekClick.shift.rawValue),
                                                     (title: SettingsWords.text("Option-click"), value: PeekClick.option.rawValue)],
                         selection: $peekClick)
                    .fixedSize()
            }
            .settingsAnchor("peek-click")
            SettingsRow("Close agent tabs", detail: "Close inactive tabs after a task ends. Unread results and kept tabs stay open.") {
                DropMenu("Close agent tabs", options: AgentTabsAfter.allCases.map { (title: $0.title, value: $0) },
                         selection: $prefs.agentTabsAfter)
                    .fixedSize()
            }
            .settingsAnchor("agents-cleanup")
            SettingsRow("Today's tabs in every window", detail: "Share Today tabs across windows in the same space. Each window keeps its selected tab.") {
                Toggle(SettingsWords.text("Today's tabs in every window"), isOn: $prefs.todayEveryWindow)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("today-every-window")
            // Only with spaces: without them there is one row to go through.
            if prefs.usesSpaces {
                SettingsRow("Recent tabs come from", detail: recentKey.keys.map { "Choose which spaces appear in \($0.settingsHint)." } ?? "Choose which spaces appear in the tab switcher.") {
                    DropMenu("Recent tabs come from", options: SwitchReach.allCases.map { (title: $0.title, value: $0) },
                             selection: Binding(get: { SwitchReach(rawValue: reach) ?? .brought }, set: { reach = $0.rawValue }))
                        .fixedSize()
                }
                .settingsAnchor("switcher-reach")
            }
        }
        Section {
            SettingsRow("Energy Saver", detail: "Saves battery by limiting background activity and visual effects, such as smooth scrolling and video frame rates.") {
                DropMenu("Energy Saver", options: EnergySaver.allCases.map { (title: SettingsWords.text($0.title), value: $0.rawValue) },
                         selection: Binding(get: { energySaver }, set: {
                             EnergySaver.current = EnergySaver(rawValue: $0) ?? .off
                         }))
                    .fixedSize()
            }
            .settingsAnchor("energy-saver")
        }
        AwakeSiteSettings()
        Section {
            SettingsRow("⌘-clicking links makes folders", detail: "Group a page and its opened links. The folder is removed when one tab remains.") {
                Toggle(SettingsWords.text("⌘-clicking links makes folders"), isOn: $prefs.linkFolders)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("link-folders")
            SettingsRow("Add emoji to new folders", detail: "Add an emoji to folders containing multiple sites.") {
                Toggle(SettingsWords.text("Add emoji to new folders"), isOn: $prefs.folderEmoji)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("folder-emoji")
            SettingsRow("⌥⇧-clicking a tab makes a folder", detail: "Group the clicked tab with the active tab or its folder.") {
                Toggle(SettingsWords.text("⌥⇧-clicking a tab makes a folder"), isOn: $prefs.optShiftFolders)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("opt-shift-folders")
            SettingsRow("Group tabs for meetings", detail: "Group meeting tabs in a folder with the meeting name and remaining time.") {
                Toggle(SettingsWords.text("Group tabs for meetings"), isOn: $prefs.meetingFolders)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("meeting-folders")
            SettingsRow("Picture in Picture automatically", detail: floatKey.keys.map { "Float videos when you leave the tab or Yab, and on calls. Use \($0.settingsHint) manually." } ?? "Float videos when you leave the tab or Yab, and on calls.") {
                Toggle(SettingsWords.text("Picture in Picture automatically"), isOn: $prefs.floatsOnLeave)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("float-leave")
            SettingsRow("Snap Picture in Picture to edges", detail: "Turn off to leave the video window wherever you place it.") {
                Toggle(SettingsWords.text("Snap Picture in Picture to edges"), isOn: $snapPiPToEdges)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("float-snap")
            .onChange(of: snapPiPToEdges) { _, on in
                for browser in BrowserWindows.shared.browsers { browser.floater.snapToEdges(on) }
            }
            SettingsRow("Show media player", detail: "Control background media below the spaces. Hiding the player keeps playback running.") {
                Toggle(SettingsWords.text("Show media player"), isOn: $prefs.showsPlayer)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("player")
            SettingsRow("Your next meeting", detail: meetingKey.keys.map { "Show a meeting countdown on pinned calendars. Join from any app with \($0.settingsHint)." } ?? "Show a meeting countdown and Join button on pinned calendars.") {
                Toggle("Your next meeting", isOn: Binding(
                    get: { meetings.wanted },
                    set: { on in
                        meetings.wanted = on
                        if on { Task { _ = await meetings.ask() } }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .settingsAnchor("meetings")
        }
    }
}

/// The choices for the empty field over the current page, as Fallback Commands.
struct FieldPageSettings: View {
    @State private var revision = 0
    @State private var hovered: String?
    @State private var anchor = DropAnchor.Place()
    @State private var listing = false

    var body: some View {
        let _ = revision
        let kept = FieldPageRows.entries()
        let visible = FieldPageRows.visible()
        let base = FieldPageRows.base()
        Section {
            ForEach(base) { row in
                line("base:" + row.id, row.title, row.symbol, "Always") {
                    FieldPageRows.hide(row)
                }
                .draggable("page-base:" + row.id)
                .dropDestination(for: String.self) { dropped, _ in
                    guard let value = dropped.first, value.hasPrefix("page-base:"),
                          let moved = FieldPageRows.Base(rawValue: String(value.dropFirst("page-base:".count))),
                          moved != row, let from = base.firstIndex(of: moved),
                          let to = base.firstIndex(of: row) else { return false }
                    let after = from < to ? base.index(after: to) : to
                    FieldPageRows.move(moved, before: base.indices.contains(after) ? base[after] : nil)
                    return true
                }
            }
            ForEach(kept) { entry in
                line("kept:" + entry.id, entry.name, entry.kind?.symbol ?? "puzzlepiece.extension", "Kept") {
                    FieldPageRows.keep(entry, on: false)
                }
                .draggable("page-kept:" + entry.id)
                .dropDestination(for: String.self) { dropped, _ in
                    guard let value = dropped.first, value.hasPrefix("page-kept:") else { return false }
                    let id = String(value.dropFirst("page-kept:".count))
                    guard id != entry.id, let from = kept.firstIndex(where: { $0.id == id }),
                          let to = kept.firstIndex(of: entry) else { return false }
                    let after = from < to ? kept.index(after: to) : to
                    FieldPageRows.moveKept(id, before: kept.indices.contains(after) ? kept[after].id : nil)
                    return true
                }
            }
            ForEach(visible) { kind in
                line("kind:" + kind.id, kind.title, kind.symbol, kind.category) {
                    FieldPageRows.hide(kind)
                }
                .draggable("page-kind:" + kind.id)
                .dropDestination(for: String.self) { dropped, _ in
                    guard let value = dropped.first, value.hasPrefix("page-kind:"),
                          let moved = FieldPageRows.Kind(rawValue: String(value.dropFirst("page-kind:".count))),
                          moved != kind, let from = visible.firstIndex(of: moved),
                          let to = visible.firstIndex(of: kind) else { return false }
                    let after = from < to ? visible.index(after: to) : to
                    FieldPageRows.move(moved, before: visible.indices.contains(after) ? visible[after] : nil)
                    return true
                }
            }
            FieldAddLine("Add Row", press: openList)
                .overlay(DropAnchor(place: anchor, title: "Add Row", press: openList, hover: { _ in }))
        } header: {
            Text("On a Page")
                .settingsAnchor("page-kept")
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in revision += 1 }
    }

    private func openList() {
        guard !listing, let view = anchor.view, view.window != nil else { return }
        let bases = FieldPageRows.hiddenBase(), rows = FieldPageRows.addable(), hidden = FieldPageRows.hidden()
        guard !bases.isEmpty || !rows.isEmpty else { return }
        let firstKept = rows.firstIndex { !hidden.contains($0) }.map { $0 + bases.count }
        let options = bases.map { DropList.Line(title: $0.title, picture: Glyphs.image($0.symbol, side: 16)) }
            + rows.map { DropList.Line(title: $0.title, picture: Glyphs.image($0.symbol, side: 16)) }
        let list = DropList(options: options, chosen: 0, divideBefore: firstKept == 0 ? nil : firstKept, inset: DropFace.inset)
        listing = true
        DropPopup.show(list, under: view, trailing: true) { index in
            listing = false
            guard let index else { return }
            if bases.indices.contains(index) {
                FieldPageRows.add(bases[index])
            } else if rows.indices.contains(index - bases.count) {
                FieldPageRows.add(rows[index - bases.count])
            }
        }
    }

    private func line(_ id: String, _ title: String, _ symbol: String, _ category: String, remove: (() -> Void)? = nil) -> some View {
        let over = hovered == id && remove != nil
        return FieldLine(title, mark: {
            FieldGripMark(over: over) { FieldLineMark(symbol: symbol) }
        }, status: {
            Text(SettingsWords.text(category))
                .foregroundStyle(.secondary)
        }, end: {
            FieldLineRemove(shown: over, label: "Remove \(title)") { remove?() }
        })
        .contentShape(Rectangle())
        .settingsRowHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .contextMenu {
            if let remove { Button(SettingsWords.text("Remove"), action: remove) }
        }
    }
}

/// Settings › Passwords.
struct PasswordsPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: SettingsModel
    /// A connected manager's extension turning on or off changes who saves.
    @ObservedObject private var extensions = Extensions.shared
    @ObservedObject private var managers = ManagerExtensions.shared
    @ObservedObject private var connections = PasswordManagers.Connections.shared

    var body: some View {
        if let id = PasswordManagersPlace.manager(model.opened) {
            ConnectManagerPage(id: id)
        } else if model.opened == PasswordManagersPlace.connect {
            ConnectManagersPage(model: model)
        } else {
            home
        }
    }

    @ViewBuilder private var home: some View {
        PageHero(page: .passwords)
        PasswordManagersSection(prefs: prefs, model: model, browser: browser)
        if prefs.usesYabPasswords {
            Section {
                FeatureRow("Saved in Yab", icon: "key", tint: .systemGray,
                           detail: "View saved passwords.") {
                    Button(SettingsWords.text("Open")) { openPasswords() }.settingsButton()
                }
                    .settingsAnchor("your-passwords")
                PasswordBringer(browser: browser, anchor: "bring-passwords", icon: true)
            }
            Section {
                // The person's while Yab asks, Apple Passwords connected too;
                // held only by a manager's extension that asks itself.
                let offer = prefs.passwordSource.offerSwitch(saves: prefs.savesPasswords)
                SettingsSwitch("Offer to save passwords", isOn: offer.enabled ? $prefs.savesPasswords : .constant(false))
                    .disabled(!offer.enabled).settingsAnchor("save-passwords")
                SettingsSwitch("Fill in passwords", isOn: $prefs.fillsPasswords).settingsAnchor("fill")
                SettingsSwitch("Ask for \(Vault.proof) before filling", isOn: $prefs.provesToFill).settingsAnchor("prove")
                // Off and still until Apple grants the browser passkeys entitlement:
                // a switch that reads on but can't work looks broken.
                SettingsSwitch("Offer passkeys", isOn: prefs.passkeysPossible ? $prefs.passkeys : .constant(false))
                    .disabled(!prefs.passkeysPossible)
                    .settingsAnchor("passkeys")
                SettingsNote(passwordsNote)
            }
        } else {
            Section {
                FeatureRow("Saved in Yab", icon: "key", tint: .systemGray,
                           detail: "Passwords remain in your keychain. Enable Yab passwords to fill them.") {
                    Button(SettingsWords.text("Open")) { openPasswords() }.settingsButton()
                }
                    .settingsAnchor("your-passwords")
            }
        }
        if !Vault.never.isEmpty {
            Section {
                SettingsRow("Sites you turned down", detail: "Password saving is disabled for \(Vault.never.count) sites.") {
                    Button(SettingsWords.text("Forget")) {
                        Vault.never = []
                        browser.announce("Yab offers on every site again", mark: "key", on: SettingsWindow.shared.toaster)
                    }
                    .settingsButton()
                }
                .settingsAnchor("never")
            }
        }
    }

    /// Who saves, how long a yes lasts, and what passkeys need.
    private var passwordsNote: String {
        var saving = "Password saving requires approval once per site."
        // One list a box: a password manager's extension on in Yab fills
        // and saves on pages by itself (docs/password-manager-fields.md).
        if let owner = PasswordManagers.fieldOwner {
            saving = "\(owner.name) fills and saves passwords on pages while its extension is on."
        }
        let passkeys = !prefs.passkeysPossible
            ? "Passkeys are not yet available in Yab."
            : Passkeys.access == .denied
            ? "Allow passkeys in System Settings › Privacy & Security › Passkeys Access for Web Browsers."
            : "Passkeys use Touch ID, iCloud, a phone nearby or a security key."
        // How long a yes lasts, so a second fill that isn't asked about
        // doesn't read as the switch not working.
        let proving = prefs.provesToFill ? " Approval lasts \(Int(Vault.grace / 60)) minutes or until this Mac locks. Agent sign-ins always require approval." : ""
        return "\(saving)\(proving) \(passkeys)"
    }

    /// The passwords are a place in the box, over the page in front.
    private func openPasswords() {
        browser.tuning = false
        browser.openPlace(.passwords)
    }
}

/// You, your cards and addresses, and whole forms filled from them:
/// Autofill's place in the box, as a page.
struct AutofillPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var fillKey = Keymap.shared.slot(.fillForm)

    var body: some View {
        PageHero(page: .autofill)
        Section {
            FeatureRow("You, your cards and addresses", icon: "creditcard", tint: .systemGray,
                       detail: "Manage saved profile details, payment cards and addresses.") {
                Button(SettingsWords.text("Open")) { openAutofill() }.settingsButton()
            }
                .settingsAnchor("your-cards")
            WalletBringer(browser: browser, anchor: "bring-cards", icon: true)
            SettingsSwitch("Offer to save cards and addresses", isOn: $prefs.savesCards).settingsAnchor("save-cards")
            SettingsSwitch("Fill in cards and addresses", isOn: $prefs.fillsCards).settingsAnchor("fill-cards")
            SettingsNote("Each card fill requires \(Vault.proof). Saved security codes are included. Agents cannot read card numbers.")
        }
        Section {
            SettingsSwitch("Fill whole forms", isOn: $prefs.fillsForms).settingsAnchor("fill-forms")
            SettingsSwitch("Draft answers to questions with AI", isOn: $prefs.draftsForms).settingsAnchor("draft-forms")
                .disabled(!prefs.fillsForms)
            SettingsNote("Use Fill the form or \(fillKey.keys?.settingsHint ?? "the assigned shortcut") for saved details and previous answers. Payment, banking, ID and consent fields require manual input. Forms are never submitted automatically. AI drafts send the question, page and profile to Claude or ChatGPT.")
        }
        OneTimeCodes(prefs: prefs)
    }

    /// You, the cards and addresses, the same way.
    private func openAutofill() {
        browser.tuning = false
        browser.openPlace(.autofill)
    }
}

/// Settings › Privacy.
struct PrivacyPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: SettingsModel
    @ObservedObject private var shield = Shield.shared
    @ObservedObject private var extensions = Extensions.shared
    @State private var showsPaused = false
    @State private var refresh = 0
    static let manage = "__manage"

    /// The ad blocker extensions installed, on or off.
    private var blockers: [Installed] { Blockers.installed }

    var body: some View {
        // The blocker is one switch, and the site in front if it breaks
        // there: on this page, not one of its own.
        Section {
            FeatureRow("Ad blocker", icon: "checkmark.shield", tint: .systemGreen, detail: shieldLine) {
                Toggle(SettingsWords.text("Block ads and trackers"), isOn: $prefs.shielded)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("shield")
            if let trouble = shield.trouble {
                SettingsRow(trouble, detail: "Ad blocking is unavailable until this error is resolved.") {
                    Button("Try Again") { shield.compile() }.settingsButton()
                }
            } else {
                // One blocker at a time, once there is a second to choose
                // (docs/ad-blocker-source.md).
                if !blockers.isEmpty, prefs.shielded {
                    if let failed = shield.failed {
                        SettingsRow("\(Blockers.name(failed))'s rules didn't load", detail: "Using built-in blocking until the extension is ready.") {
                            Button("Try Again") { Blockers.retry() }.settingsButton()
                        }
                        .settingsAnchor("shield-failed")
                    }
                    SettingsRow("Blocking with", detail: shield.chosen == nil ? blockers.first.map { "\($0.name) is installed and turned off." } ?? "" : "") {
                        DropMenu("Blocking with",
                                 options: [(title: "Built-in", value: "")]
                                     + blockers.map { item in (title: item.id == shield.chosen || item.enabled ? item.name : "\(item.name) · Turned off", value: item.id) }
                                     + [(title: "Manage Extensions…", value: PrivacyPage.manage)],
                                 selection: Binding(
                                     get: { shield.chosen ?? "" },
                                     set: { picked in
                                         if picked == PrivacyPage.manage {
                                             ExtensionMenu.manage(Extensions.shared)
                                         } else {
                                             Blockers.use(picked.isEmpty ? nil : picked)
                                         }
                                     }
                                 ),
                                 divideBefore: PrivacyPage.manage)
                            .fixedSize()
                    }
                    .settingsAnchor("shield-source")
                    if case .extension(let id) = shield.source {
                        SettingsRow("\(Blockers.name(id)) settings", detail: "Filter modes, rule sets, trusted sites.") {
                            Button(SettingsWords.text("Open")) { Extensions.shared.openOptions(id) }.settingsButton()
                        }
                        .settingsAnchor("shield-source-settings")
                    }
                }
                if let host = browser.hereHost, prefs.shielded {
                    SettingsSwitch("Block on \(host)", isOn: Binding(
                        get: { !Shield.shared.isPaused(on: host) },
                        set: { on in
                            if !browser.pauseShield(host, !on), let tab = browser.active { browser.reloadForChange(tab, .blocking) }
                        }
                    ))
                    .settingsAnchor("shield-here")
                }
                if !shield.paused.isEmpty {
                    let count = shield.paused.count
                    SettingsRow(count == 1 ? "Turned off on 1 site" : "Turned off on \(count) sites",
                                detail: Store.settings.string(forKey: "shield.pausedFrom").map { "Brought from \($0)." } ?? "") {
                        Button(SettingsWords.text(showsPaused ? "Hide" : "Show")) { showsPaused.toggle() }.settingsButton()
                    }
                    .settingsAnchor("shield-paused")
                    if showsPaused {
                        ForEach(shield.paused.sorted(), id: \.self) { host in
                            SettingsRow(host) {
                                Button(SettingsWords.text("Forget")) {
                                    browser.pauseShield(host, false)
                                    refresh += 1
                                }
                                .settingsButton()
                            }
                        }
                        .id(refresh)
                    }
                }
            }
        }
        // The lists Built-in blocks with, a group of their own under the
        // Ad blocker's (row 1108's redesign).
        if shield.trouble == nil, prefs.shielded, shield.chosen == nil {
            ShieldSourceSettings()
        }
        Section {
            FeatureRow(.history, detail: "Search visited pages and their content.", model: model)
                .settingsAnchor("your-history")
            FeatureRow("Camera and microphone", icon: "video", tint: .systemPink,
                       detail: "Reset site permissions to ask again.") {
                Button(SettingsWords.text("Forget")) { browser.forgetCaptureChoices(on: SettingsWindow.shared.toaster) }.settingsButton()
            }
            .settingsAnchor("capture")
        }
        // Everything that can't be taken back waits here at the bottom, out
        // of the way, and the one that signs you out asks first.
        SafeBrowsingSettings()
        SentToYabSettings()
        Section("Clear data") {
            SettingsRow("Cache", detail: "Cached website files.") {
                Button(SettingsWords.text("Clear")) { browser.clearCache(on: SettingsWindow.shared.toaster) }.settingsButton()
            }
            .settingsAnchor("cache")
            SettingsRow("Cookies and sign-ins", detail: "Clearing cookies signs you out of all sites.") {
                Button {
                    confirm(Question(
                        title: "Sign out everywhere?", detail: "Every site forgets you on this Mac. Your passwords stay.",
                        glyph: "rectangle.portrait.and.arrow.right", yes: "Sign Out", danger: true, place: .settings
                    )) { browser.clearSites(on: SettingsWindow.shared.toaster) }
                } label: {
                    Text("Sign Out…")
                }
                .buttonStyle(.yab(.secondary, .regular, tint: ButtonCSS.danger))
            }
            .settingsAnchor("cookies")
        }
    }

    /// The ad blocker's row says whether it is on, or what is wrong.
    private var shieldLine: String {
        if shield.trouble != nil { return "Not blocking until a problem clears." }
        guard prefs.shielded else { return "Off. Every site loads everything it asks for." }
        if let chosen = shield.chosen {
            let name = Blockers.name(chosen)
            if shield.failed == chosen { return "\(name)'s rules didn't load. Built-in blocks meanwhile." }
            if shield.source == .extension(chosen) { return "\(name) blocks ads and trackers. YouTube's ads are still taken out by Yab." }
            return "Built-in blocks until \(name) is ready."
        }
        // What Built-in blocks with: "208,887 rules from 9 lists · updated 12 min ago".
        let selected = Shield.selectedSources(disabling: shield.disabledSources, custom: shield.customSources)
        let lists = shield.facts.isEmpty ? selected.count : selected.filter { shield.facts[$0.name] != nil }.count
        return ShieldListWords.summary(rules: shield.builtRules, lists: lists, fetched: shield.fetchedAt) ?? "Ads and trackers never load."
    }
}

/// Settings › Privacy › History.
struct HistoryPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    var body: some View {
        PageHero(page: .history)
        Section {
            FeatureRow("Your history", icon: "clock", tint: .systemOrange,
                       detail: "Search visited pages by their content.") {
                Button(SettingsWords.text("Open")) {
                    browser.tuning = false
                    browser.openPlace(.history)
                }
                .settingsButton()
            }
            .settingsAnchor("your-history-open")
        }
        Section {
            SettingsRow("Remember what pages say", detail: "Store page text on this Mac for history search.") {
                Toggle(SettingsWords.text("Remember what pages say"), isOn: $prefs.diaryText)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .settingsAnchor("diary-text")
        }
        Section {
            SettingsRow("Clear history", detail: "Remove all browsing history from this Mac.") {
                Button {
                    confirm(Question(
                        title: "Clear all your history?", detail: "Remove all browsing history from this Mac. Bookmarks and passwords are kept.",
                        glyph: "clock", yes: "Clear History", danger: true, place: .settings
                    )) { browser.clearHistory(on: SettingsWindow.shared.toaster) }
                } label: {
                    Text("Clear…")
                }
                .buttonStyle(.yab(.secondary, .regular, tint: ButtonCSS.danger))
            }
            .settingsAnchor("history")
        }
    }
}

/// Settings › About.
struct AboutPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var model: SettingsModel
    var body: some View {
        Section {
            VStack(spacing: 4) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .padding(.bottom, 4)
                // The name and the line the welcome says first.
                Text("yet another browser.").font(.system(size: 20, weight: .semibold))
                Text("Version \(Updater.version)").foregroundStyle(.secondary)
                Text("A browser for your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                Text("© 2026 Serafim Korablev")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
        }
        StampAboutSection()
        Section {
            link("Send feedback") { Links.writeFeedback() }
                .settingsAnchor("feedback")
            link("Join the community on X") { Links.openFromSettings(Links.community) }
                .settingsAnchor("community")
            SettingsRow("Welcome") {
                // Over the browser window, from the first frame: the
                // settings step aside so the intro has the screen.
                Button("Show Again") {
                    browser.tuning = false
                    browser.welcoming = true
                    LaunchArrival.shared.replay(browser)
                }
                .settingsButton()
            }
            .settingsAnchor("welcome")
        }
        Section {
            FeatureRow(.credits, detail: "Search, Arc and Raycast, with thanks.", model: model)
                .settingsAnchor("credits")
            FeatureRow(.inviteFriends, detail: "Invite friends and unlock exclusive app icons.", model: model)
                .settingsAnchor("invite")
        }
    }
}

/// Settings › Privacy, the anti-phishing list (SafeBrowsing): off unless
/// asked for, as everything that reaches the network is. The list is
/// downloaded whole and checked on this Mac; no page or visit is sent.
/// Only where there is a feed to take it from.
struct SafeBrowsingSettings: View {
    @AppStorage(SafeBrowsing.key, store: Store.settings) private var on = false

    var body: some View {
        if Updater.site != nil {
            Section("Safe Browsing") {
                SettingsRow("Warn before phishing sites", detail: "Check sites against a list downloaded daily. Checks stay on this Mac. Opening a flagged site requires approval each session.") {
                    Toggle("Warn before phishing sites", isOn: $on)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .settingsAnchor("safe-browsing")
                .onChange(of: on) { _, enabled in
                    if enabled { Task { await SafeBrowsing.refresh() } }
                }
            }
        }
    }
}

/// Settings › Privacy, "Sent to Yab": what Yab sends about you, crash
/// reports and the count of active days, beside the blocker and the data
/// cleared, since data collection is a privacy matter. Only where
/// there is somewhere to send them.
struct SentToYabSettings: View {
    @AppStorage(Crashes.key, store: Store.settings) private var sendsCrashes = false
    @AppStorage(Activity.key, store: Store.settings) private var sendsActivity = true

    var body: some View {
        if Updater.site != nil {
            Section(SettingsWords.text("Sent to Yab")) {
                SettingsRow("Automatically send crash reports", detail: "Send crash and hang reports, Yab and macOS versions. No page content or typed text. When off, each new crash asks for approval.") {
                    Toggle(SettingsWords.text("Automatically send crash reports"), isOn: $sendsCrashes)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .settingsAnchor("crashes")
                if !Store.testing && !Store.development {
                    SettingsRow("Count me in anonymous usage stats", detail: "Report daily app usage. No personal details, pages, searches or history.") {
                        Toggle(SettingsWords.text("Count me in anonymous usage stats"), isOn: $sendsActivity)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .settingsAnchor("activity")
                    .onChange(of: sendsActivity) { _, enabled in
                        if enabled { Activity.shared.sendIfDue() }
                    }
                }
            }
        }
    }
}

/// Where yab came from, said warmly: the code it grew from, the apps
/// whose care it learned from, and what their licenses ask to show.
struct CreditsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        PageHero(page: .credits)
        Section {
            CreditRow(art: "Search", name: "Search", by: "Office Commun",
                      thanks: "The open-source browser Yab grew from. Every page here started as theirs.",
                      site: "https://github.com/driceroland/Search")
                .settingsAnchor("thanks")
            CreditRow(art: "Arc", name: "Arc", by: "The Browser Company",
                      thanks: "Much of how Yab looks is inspired by Arc. Thank you for showing a browser can be calm, warm and a little playful.",
                      site: "https://arc.net")
            CreditRow(art: "Raycast", name: "Raycast", by: "Raycast",
                      thanks: "Yab’s settings, commands and AI are inspired by Raycast. Thank you for showing how kind a Mac app can feel.",
                      site: "https://www.raycast.com")
        }
        // What the licenses of code inside the app ask to be shown.
        if let notices = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") {
            Section {
                link("Acknowledgements") { NSWorkspace.shared.open(notices) }
                    .settingsAnchor("acknowledgements")
            } footer: {
                SettingsNote("Licenses for open-source software used in Yab.")
            }
        }
    }
}

/// A row that is an errand: the whole row is the button, and the arrow
/// says it leaves the app.
@MainActor private func link(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            Symbol("arrow.up.right", size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}

/// Something that can't be taken back, done once the card over the pane
/// has its yes, ⌘Return or the red button.
@MainActor private func confirm(_ question: Question, then run: @escaping () -> Void) {
    Task { if await Questions.shared.ask(question) { run() } }
}

/// At the foot of General once the step at the top is gone, never both,
/// and not while the browsers are still being found for it.
private struct BringInFoot: View {
    @ObservedObject var bringing: Bringing
    @ObservedObject var model: SettingsModel

    var body: some View {
        if !GeneralSteps.offersBring(bringing), bringing.loaded || Bringing.everBrought {
            Section {
                FeatureRow(.bringIn, title: "Bring in from another browser", detail: "Tabs, passwords, cards, bookmarks, history and extensions.", model: model)
                    .settingsAnchor("bring-in")
            }
        }
    }
}
