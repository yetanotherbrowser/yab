import Security
import Combine
import SwiftUI

// Everything there is to set, in one observable place.
//
// Each of these is a line in the settings file and nothing more; the object
// exists so that a panel can bind to them and the views that draw one can
// redraw when it changes, and only those: it is @Observable, so a body that
// reads `prefs.glyph` depends on the glyph alone (docs/state-observation.md).
// Defaults are chosen so that a browser nobody has configured behaves the
// way it always did.

/// How roomy the column is: Arc's sizes, or the tighter ones Yab had
/// first. Every size down the column comes from here (SideBar, SidePlate),
/// so the rows, the pins and the address plate change together.
enum Density: String, CaseIterable, Identifiable {
    case comfortable, compact

    var id: String { rawValue }

    /// The one the column draws with: the saved one, then kept in step
    /// with Preferences.density.
    nonisolated(unsafe) static var current: Density = saved
    static var saved: Density { Store.settings.string(forKey: key).flatMap(Density.init) ?? .comfortable }
    static let key = "sidebar.density"

    /// A tab's row: Arc's 36, measured on one screen against its own. Its
    /// lit ground is the 34 inside it (TabRow's vertical 6 around 22 of
    /// content), Arc's own 34.
    var row: CGFloat { self == .compact ? 28 : 36 }
    /// The gap under a row: with the row, Arc's pitch of 41 (measured at 2x
    /// on 2026-10-12, https://claude.ai/artifact/7rwm22XmubBet4DschWSNE);
    /// compact keeps its rows close.
    var gap: CGFloat { self == .compact ? 4 : 5 }
    /// The line over today's tabs, the gap under it left out: Arc's is no
    /// row but a strip, 58 from the middle of the row over it to New Tab's
    /// where rows step 41 (measured at 2x on 2026-10-20), so 12 of its own
    /// and the gap; compact the same share of its row.
    var line: CGFloat { self == .compact ? 9 : 12 }
    /// The stroke's top in that strip: 10 under the row over it, 12 over
    /// New Tab, as Arc draws it.
    var lineDrop: CGFloat { self == .compact ? 3 : 5 }
    /// A row's ground's corner: Arc's 10; compact keeps a control's 8, the
    /// same share of its shorter row.
    var radius: CGFloat { self == .compact ? Radius.control : 10 }
    /// A row's mark and the gap from it to the title.
    var mark: CGFloat { self == .compact ? 15 : 16 }
    /// The folder outline spans 18 points of its 24-point drawing grid.
    var folder: CGFloat { mark * 24 / 18 }
    var markGap: CGFloat { self == .compact ? 8 : 10 }
    /// The cross's slot's inset from a row's end (the cross is RowPlate's).
    var endInset: CGFloat { self == .compact ? 7 : 11 }
    /// A pin's height (Arc's is 45), and the gap between pins: the
    /// column's own 8 at either density, not Arc's wider one.
    var pin: CGFloat { self == .compact ? 34 : 45 }
    var pinGap: CGFloat { 8 }
    /// The address plate's height, and the gap under it before the pins,
    /// the same 8.
    var plate: CGFloat { self == .compact ? 34 : 36 }
    var plateBelow: CGFloat { 8 }
    /// A tab across the top: the lit ground of a row of the column, 34 as
    /// Arc's (a comfortable row's 36 less its point of air each side), a
    /// compact row's 28 (alpha report, 2026-10-28).
    var tab: CGFloat { self == .compact ? 28 : 34 }
    /// The air over and under a tab's 16 of content across the top.
    var tabPad: CGFloat { (tab - 16) / 2 }
}

/// The square under the pointer on what a tab holds, its cross, the
/// agent's face, the speaker, the way home, the site's door, the book, and
/// the cross drawn on it: one system for a row of the column and a tab
/// across the top alike, where only the ground's height tells them apart
/// (alpha report, 2026-10-13). A sixth of the ground's height in
/// from it all round, in whole points (36: 6, 28: 4), so it is the ground
/// less twice that (Arc's 24 in its 36; 20 in a 28); its corner the
/// ground's (Density.radius) less the inset, concentric with it; the cross
/// on it half the square and four (Arc's 16 on its 24; 14 on a 20), its
/// stroke an eighth of that. Every one of them is drawn from here.
struct RowPlate: Equatable {
    /// The ground's height: the row's, or the tab's across the top.
    let ground: CGFloat
    /// The square's side, its inset from the ground and its corner.
    let side: CGFloat
    let inset: CGFloat
    let radius: CGFloat
    /// How many points across the cross and the minus on it are drawn.
    let cross: CGFloat

    /// Its ink under the pointer, and while what it holds is on (the
    /// door's panel up, the page being read).
    static let hover: Double = 0.1
    static let held: Double = 0.14

    /// In a ground `height` tall.
    init(in height: CGFloat) {
        ground = height
        inset = (height / 6).rounded(.down)
        side = height - 2 * inset
        radius = max(0, Density.current.radius - inset)
        cross = side / 2 + 4
    }

    /// In a row of the column: 24 in its 36, six in (compact 20 in 28, four in).
    static var column: RowPlate { RowPlate(in: Density.current.row) }
    /// In a tab across the top, as tall as a lit row of the column
    /// (Density.tab): 24, five in; compact 20, four in.
    static var strip: RowPlate { RowPlate(in: Density.current.tab) }

    /// The square itself, drawn past what it is behind, so nothing moves
    /// for it.
    func square(held: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous) // design: concentric with the row (RowPlate)
            .fill(Palette.ink.opacity(held ? Self.held : Self.hover))
            .frame(width: side, height: side)
    }

    /// The way home on a kept tab's mark (PinnedHome.swift), as Arc draws
    /// its pinned tab's: no inset, a square the ground's height at its left
    /// end, its corners there the ground's own and straight where it stops
    /// (measured on Arc, evals/kept-home: 36 square in its 36 row).
    func edge() -> some View {
        UnevenRoundedRectangle(topLeadingRadius: Density.current.radius, bottomLeadingRadius: Density.current.radius,
                               style: .continuous) // design: the ground's own corners (Density.radius), straight inside
            .fill(Palette.ink.opacity(Self.hover))
            .frame(width: ground, height: ground)
    }
}

/// What a tab wears beside its title, and what a pinned one is reduced to: a
/// letter, or the site's own icon.
enum Glyph: String, CaseIterable, Identifiable {
    case letters, icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .letters: return "Letter"
        case .icons: return "Site icon"
        }
    }
}

/// When the row of bookmarks stands over the page: never or always. There
/// is no new tab page to keep it over, so no Chrome-like third way.
enum BookmarkBarMode: String, CaseIterable, Identifiable {
    case never, always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .always: return "Always"
        }
    }
}

/// What each bookmark in the row shows: its icon and name; its icon alone, so many more fit; or a folder its name
/// and a site its icon, so a folder, which has no icon of its own to tell
/// it by, can still be told apart (feedback #106).
enum BookmarkStyle: String, CaseIterable, Identifiable {
    case names, icons, folders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .names: return "Icons and names"
        case .icons: return "Icons only"
        case .folders: return "Icons, folders named"
        }
    }

    /// Whether `folder`'s name, or a site's, is written beside its icon.
    func named(folder: Bool) -> Bool {
        switch self {
        case .names: return true
        case .icons: return false
        case .folders: return folder
        }
    }
}

/// Glass was one switch for every window, from Settings › Experimental,
/// until it became a step of each space's look (the wave's end, LookSlider).
/// Kept to carry a Mac that had it on over (Spaces.glazeOnce).
enum GlassExperiment {
    static let key = "experimental.glass"
    static let offeredKey = "experimental.glass.offered"
}

@MainActor
@Observable
final class Preferences: ObservableObject, Relaying {
    /// Each setting's new values for Combine (`changes(\.name)`), and any of them
    /// about to change (`relay.any`), as @Published told them.
    @ObservationIgnored let relay = ChangeRelay<Preferences>()
    /// ObservableObject's publisher, kept here. With no @Published left
    /// (the state is @Observable), Combine's own `objectWillChange` found
    /// it by walking every stored property through reflection on each
    /// read, and SwiftUI reads it for every @ObservedObject on every
    /// update: about 0.1 ms a read of a Browser or a Tab (bench
    /// willchange), many times over in every pass (feedback #120).
    nonisolated let objectWillChange = ObservableObjectPublisher()
    /// A word saved in the British spelling yab once wrote, as it is
    /// spelled now.
    private static func american(_ word: String?) -> String? {
        switch word {
        case "colour": return "color"
        case "grey": return "gray"
        default: return word
        }
    }

    @ObservationIgnored private let store = Store.settings
    @ObservationIgnored private var displayWatch: AnyCancellable?
    /// A synced default is kept globally; a window can still wear its
    /// selected space's paint without writing that paint back as a default.
    @ObservationIgnored private var projectingSpacePaint = false

    /// A local socket a script can drive the browser through, in tabs of its
    /// own. Off unless asked for.
    var bench: Bool {
        willSet { relay.send(\.bench, newValue) }
        didSet { store.set(bench, forKey: "bench") }
    }
    /// Agents keep what they learn about you between tasks, on unless
    /// asked not to, so stored the other way round.
    var agentsRemember: Bool {
        willSet { relay.send(\.agentsRemember, newValue) }
        didSet { store.set(!agentsRemember, forKey: "agents.forget"); if !agentsRemember { ContextPrivacy.shared.revoke() } }
    }
    /// AI in Yab (Settings › AI): On, When Asked or Off, kept where every
    /// surface reads it (AIUse), the mail engine's model included.
    var aiUse: AIUse.Level {
        willSet { relay.send(\.aiUse, newValue) }
        didSet {
            _ = AppleWritingTools.shared
            AIUse.set(aiUse, in: store)
            ShortNames.enabled = tidyTitles && AIUse.allows(.background, in: store)
        }
    }
    /// Hide AI Rows in Field: Ask and Task under the words and ⇥ asking
    /// put away, the switch left as it is (AIUse.rowsKey).
    var aiRowsHidden: Bool {
        willSet { relay.send(\.aiRowsHidden, newValue) }
        didSet { AIUse.setRowsHidden(aiRowsHidden, in: store) }
    }
    /// While You Browse (Settings › AI): today's tabs grouped (TidyTabs),
    /// a kept tab's title shortened (ShortNames), a folder named by what is in it
    /// (LinkFolders), a download named by what it is (DownloadNames). On
    /// unless turned off; they only ever run where Apple Intelligence or a
    /// connected plan can answer.
    var tidyTabs: Bool {
        willSet { relay.send(\.tidyTabs, newValue) }
        didSet { store.set(tidyTabs, forKey: "tidy.tabs") }
    }
    var tidyTitles: Bool {
        willSet { relay.send(\.tidyTitles, newValue) }
        didSet { store.set(tidyTitles, forKey: "tidy.titles"); ShortNames.enabled = tidyTitles && AIUse.allows(.background, in: store) }
    }
    var folderNames: Bool {
        willSet { relay.send(\.folderNames, newValue) }
        didSet { store.set(folderNames, forKey: "folders.names") }
    }
    var tidyDownloads: Bool {
        willSet { relay.send(\.tidyDownloads, newValue) }
        didSet { store.set(tidyDownloads, forKey: "tidy.downloads") }
    }
    /// How much agents ask you first: Ask, Auto, Bypass.
    var agentsAsking: AgentAsking {
        willSet { relay.send(\.agentsAsking, newValue) }
        didSet { store.set(agentsAsking.rawValue, forKey: "agents.asking") }
    }
    /// What asking about a page (⌘J) opens: the line at its foot, or a
    /// chat beside it (TaskLine.open).
    var askOpens: AskOpens {
        willSet { relay.send(\.askOpens, newValue) }
        didSet { store.set(askOpens.rawValue, forKey: "agents.askOpens") }
    }
    /// Whether a task with full access may read a one-time code from
    /// Messages, with your yes each time. Off unless asked for.
    var agentsMessages: Bool {
        willSet { relay.send(\.agentsMessages, newValue) }
        didSet { store.set(agentsMessages, forKey: "agents.messages") }
    }
    /// An agent's yes or no also on the person's other devices in Sync:
    /// iPhone, another Mac (AssistantApprovals). On unless turned off.
    var agentsAskElsewhere: Bool {
        willSet { relay.send(\.agentsAskElsewhere, newValue) }
        didSet { store.set(agentsAskElsewhere, forKey: "agents.ask-elsewhere") }
    }
    /// An agent's question rings its own two notes, in Yab and in its
    /// notification (AskSound). On unless turned off.
    var agentsAskSound: Bool {
        willSet { relay.send(\.agentsAskSound, newValue) }
        didSet { store.set(agentsAskSound, forKey: "agents.ask-sound") }
    }
    /// Finished agents' temporary tabs, after the last look at them.
    var agentTabsAfter: AgentTabsAfter {
        willSet { relay.send(\.agentTabsAfter, newValue) }
        didSet {
            guard agentTabsAfter != oldValue else { return }
            store.set(agentTabsAfter.rawValue, forKey: AgentTabsAfter.key)
            for browser in BrowserWindows.shared.browsers where browser.prefs !== self && browser.prefs.agentTabsAfter != agentTabsAfter {
                browser.prefs.agentTabsAfter = agentTabsAfter
            }
            AgentTabCleanup.shared.settingChanged()
        }
    }
    /// Light, dark, or the Mac's own.
    var look: Look {
        willSet { relay.send(\.look, newValue) }
        didSet {
            store.set(look.rawValue, forKey: "look")
            look.apply()
            // One Theme for the app: every window's settings say it, so the
            // View menu and Settings from another window, and its following
            // the Mac while System, don't go by the one it opened with.
            guard look != oldValue else { return }
            for browser in BrowserWindows.shared.browsers where browser.prefs !== self && browser.prefs.look != look {
                browser.prefs.look = look
            }
        }
    }
    /// How the page sits in the window: edge to edge, on a color, or on
    /// the site's own.
    var backdrop: Backdrop {
        willSet { relay.send(\.backdrop, newValue) }
        didSet { store.set(backdrop.rawValue, forKey: "backdrop") }
    }
    /// The color the window is painted in, or, on the site's color, the
    /// one for pages that won't say. A quiet gray unless another is picked.
    var swatch: Swatch {
        willSet { relay.send(\.swatch, newValue) }
        didSet { if !projectingSpacePaint { store.set(swatch.rawValue, forKey: "backdrop.swatch") } }
    }
    /// The color picked by hand, kept even while a swatch is chosen so
    /// going back to it finds it where it was.
    var backdropTransparency: Double {
        willSet { relay.send(\.backdropTransparency, newValue) }
        didSet { if !projectingSpacePaint { store.set(BackdropTransparency.clamp(backdropTransparency), forKey: "backdrop.transparency") } }
    }
    var backdropColor: NSColor {
        willSet { relay.send(\.backdropColor, newValue) }
        didSet { if !projectingSpacePaint { store.set(backdropColor.hex, forKey: "backdrop.color") } }
    }
    /// How much grain over the backdrop, 0 for none. Kept as on or off
    /// too, for builds from before it had an amount.
    var grain: Double {
        willSet { relay.send(\.grain, newValue) }
        didSet {
            if !projectingSpacePaint {
                store.set(grain, forKey: "backdrop.grain.amount")
                store.set(grain > 0, forKey: "backdrop.grain")
            }
        }
    }
    /// Titles down the left instead of across the top.
    var sidebar: Bool {
        willSet { relay.send(\.sidebar, newValue) }
        didSet {
            store.set(sidebar, forKey: "sidebar")
            if sidebar != oldValue { told(\.sidebar) }
        }
    }
    /// The column put away into the left edge, the page taking the window.
    /// Only ever means anything while `sidebar` is on.
    var sideShut: Bool {
        willSet { relay.send(\.sideShut, newValue) }
        didSet {
            store.set(sideShut, forKey: "sidebar.shut")
            if sideShut != oldValue { told(\.sideShut) }
        }
    }

    /// The toolbar's sidebar door. Its keyboard shortcut and edge remain.
    var sidebarButton: Bool {
        willSet { relay.send(\.sidebarButton, newValue) }
        didSet {
            store.set(sidebarButton, forKey: "sidebar.button")
            if sidebarButton != oldValue { told(\.sidebarButton) }
        }
    }

    /// How long the pointer rests at the window's edge before the column
    /// put away comes out (SideReveal).
    var sideReveal: SideReveal {
        willSet { relay.send(\.sideReveal, newValue) }
        didSet {
            guard sideReveal != oldValue else { return }
            store.set(sideReveal.rawValue, forKey: SideReveal.key)
            // One choice for the app: each window has its own settings and
            // its edge waits by them, so a choice made in one reaches the rest.
            for browser in BrowserWindows.shared.browsers where browser.prefs !== self && browser.prefs.sideReveal != sideReveal {
                browser.prefs.sideReveal = sideReveal
            }
        }
    }

    /// Those watching `path` told again, now that it holds its new value.
    ///
    /// The column has a hosting view of its own inside the window's, and
    /// both read these two. Changed inside an animation (⌘S, ⇧⌘S), the
    /// inner one's update in the property's willSet could run the window's
    /// body there and then, reading the value from before the change, and
    /// SwiftUI took that pass as the one the change asked for: with a pair
    /// on screen, the column went and the halves kept its room, or came
    /// back over halves that never made room, until the next change of
    /// anything (2026-10-13). Told once more after the value is stored,
    /// any pass it starts reads the new one.
    private func told<Value>(_ path: KeyPath<Preferences, Value>) {
        withMutation(keyPath: path) {}
    }
    /// The strip put away past the window's top edge, the page taking its
    /// room (⌘S, feedback #48). Only ever means anything while `sidebar`
    /// is off, the way `sideShut` only does while it is on.
    var stripShut: Bool {
        willSet { relay.send(\.stripShut, newValue) }
        didSet { store.set(stripShut, forKey: "strip.shut") }
    }
    /// Which edge of the window the column hangs on.
    var sideFlank: Flank {
        willSet { relay.send(\.sideFlank, newValue) }
        didSet { store.set(sideFlank.rawValue, forKey: "sidebar.flank") }
    }
    /// How wide the column is. Pulled by its edge, and remembered.
    var sideWidth: CGFloat {
        willSet { relay.send(\.sideWidth, newValue) }
        didSet { store.set(Double(sideWidth), forKey: "sidebar.width") }
    }
    /// The spaces in the column's foot as dots whatever the room, as
    /// Dia's; otherwise their emoji, dots only once too narrow for them
    /// (SpaceRowPlan). One choice for every window.
    var spaceDots: Bool {
        willSet { relay.send(\.spaceDots, newValue) }
        didSet {
            guard spaceDots != oldValue else { return }
            store.set(spaceDots, forKey: "spaces.dots")
            for browser in BrowserWindows.shared.browsers where browser.prefs.spaceDots != spaceDots {
                browser.prefs.spaceDots = spaceDots
            }
        }
    }
    /// The space's name over the column's rows, in every space (SpaceName).
    /// Off from a space's menu: the rows start under the pins and no space
    /// folds under its name. One choice for every window.
    var spaceNames: Bool {
        willSet { relay.send(\.spaceNames, newValue) }
        didSet {
            guard spaceNames != oldValue else { return }
            store.set(spaceNames, forKey: "spaces.names")
            for browser in BrowserWindows.shared.browsers where browser.prefs.spaceNames != spaceNames {
                browser.prefs.spaceNames = spaceNames
            }
            // A space folded under its name shows its kept while there is
            // no name to unfold it, and folds again with the name back.
            for browser in BrowserWindows.shared.browsers { browser.folderBook.refresh() }
        }
    }
    /// ⌘L and ⌘T as a small card: the field and as many rows as there
    /// are, no foot under the list, where the full box is one height
    /// whatever it holds. One choice for every window.
    var compactField: Bool {
        willSet { relay.send(\.compactField, newValue) }
        didSet {
            guard compactField != oldValue else { return }
            store.set(compactField, forKey: "field.compact")
            for browser in BrowserWindows.shared.browsers where browser.prefs.compactField != compactField {
                browser.prefs.compactField = compactField
            }
        }
    }
    var glyph: Glyph {
        willSet { relay.send(\.glyph, newValue) }
        didSet { store.set(glyph.rawValue, forKey: "tabs.glyph") }
    }
    /// How roomy the column is (Density). One size for every window: the
    /// sizes are read from Density.current, so each window's column is
    /// told and drawn anew.
    var density: Density {
        willSet { relay.send(\.density, newValue) }
        didSet {
            guard density != oldValue else { return }
            Density.current = density
            // The column reads its sizes from Density.current, which nothing
            // observes: every view of the window is told, as every setting
            // once told it (Browser forwards this).
            objectWillChange.send()
            store.set(density.rawValue, forKey: Density.key)
            for browser in BrowserWindows.shared.browsers where browser.prefs.density != density {
                browser.prefs.density = density
            }
        }
    }
    /// The site you are on, written across the top of the page, with the
    /// doors beside it. Off unless asked for: there is no toolbar otherwise.
    var addressBar: Bool {
        willSet { relay.send(\.addressBar, newValue) }
        didSet { store.set(addressBar, forKey: "addressbar") }
    }
    var fullURL: Bool {
        willSet { relay.send(\.fullURL, newValue) }
        didSet { store.set(fullURL, forKey: "addressbar.full-url") }
    }
    /// A peek's own address along the top of its page (PeekBand), the
    /// band's site as the address bar writes it. Off unless asked for, as
    /// the address bar is: Arc's peek has none. Every window at once.
    var peekAddress: Bool {
        willSet { relay.send(\.peekAddress, newValue) }
        didSet {
            guard peekAddress != oldValue else { return }
            store.set(peekAddress, forKey: "peek.address")
            for browser in BrowserWindows.shared.browsers where browser.prefs !== self && browser.prefs.peekAddress != peekAddress {
                browser.prefs.peekAddress = peekAddress
            }
        }
    }
    /// Back, forward and reload stand at the address bar's start while it
    /// is shown, beside the lights while it is hidden, as Arc has them with
    /// its toolbar on and off (feedback #309). No setting of its own: an
    /// "addressbar.helm" an earlier build stored is never read. With the
    /// tabs across the top the band has them anyway.
    var helmInBand: Bool { addressBar && sidebar }
    var pageZoom: Double {
        willSet { relay.send(\.pageZoom, newValue) }
        didSet {
            store.set(pageZoom, forKey: "pages.zoom")
            NotificationCenter.default.post(name: PageAppearance.changed, object: nil)
        }
    }
    var pageFonts: PageFonts {
        willSet { relay.send(\.pageFonts, newValue) }
        didSet {
            if let data = try? JSONEncoder().encode(pageFonts) { store.set(data, forKey: "pages.fonts") }
            NotificationCenter.default.post(name: PageAppearance.changed, object: nil)
        }
    }
    /// Dark pages: with the theme, always or off (DarkPages.swift). Every
    /// open page follows at once.
    var darkPages: DarkMode {
        willSet { relay.send(\.darkPages, newValue) }
        didSet {
            guard darkPages != oldValue else { return }
            store.set(darkPages.rawValue, forKey: DarkMode.key)
            DarkPages.refresh()
        }
    }
    /// The look of dark pages, from the sheet behind Customize….
    var darkLook: DarkLook {
        willSet { relay.send(\.darkLook, newValue) }
        didSet {
            guard darkLook != oldValue else { return }
            if let data = try? JSONEncoder().encode(darkLook.clamped) { store.set(data, forKey: DarkLook.key) }
            DarkPages.lookChanged()
        }
    }
    /// Additional colors in a space's gradient. Empty keeps the solid color.
    var backdropColors: [String] {
        willSet { relay.send(\.backdropColors, newValue) }
        didSet { if !projectingSpacePaint { store.set(backdropColors, forKey: "backdrop.colors") } }
    }

    /// These local defaults are also the selected space's paint.
    /// Project an explicit paint into this window only; a legacy space
    /// without one, or a window without spaces, still follows the defaults.
    func adoptPaint(_ other: Preferences, wearing paint: SpacePaint?) {
        let wasProjecting = projectingSpacePaint
        projectingSpacePaint = paint != nil
        defer { projectingSpacePaint = wasProjecting }
        let swatch = paint?.picked ?? other.swatch
        let color = paint?.own ?? other.backdropColor
        let transparency = paint?.transparency ?? other.backdropTransparency
        let grain = paint?.grain ?? other.grain
        let colors = paint?.colors ?? other.backdropColors
        if self.swatch != swatch { self.swatch = swatch }
        if backdropColor != color { backdropColor = color }
        if backdropTransparency != transparency { backdropTransparency = transparency }
        if self.grain != grain { self.grain = grain }
        if backdropColors != colors { backdropColors = colors }
    }
    /// The colors turn a step with each new tab (LookCard): only with two
    /// or more of them, where there is something to turn.
    var lookShift: Bool {
        willSet { relay.send(\.lookShift, newValue) }
        didSet { store.set(lookShift, forKey: "backdrop.shift") }
    }
    /// A page that has a color of its own tints one of yours (LookCard).
    var lookSite: Bool {
        willSet { relay.send(\.lookSite, newValue) }
        didSet { store.set(lookSite, forKey: "backdrop.site-tint") }
    }
    /// Drawings over the color, LookDrawings.Set's raw value, "" for none.
    var lookDrawings: String {
        willSet { relay.send(\.lookDrawings, newValue) }
        didSet { store.set(lookDrawings, forKey: "backdrop.drawings") }
    }
    /// The space's own light or dark, LookMode's raw value, "" to go with
    /// `look`. Worn on the window it is in (LookModeScheme).
    var lookMode: String {
        willSet { relay.send(\.lookMode, newValue) }
        didSet {
            store.set(lookMode, forKey: "backdrop.mode")
            if lookMode != oldValue { DarkPages.appearanceChanged() }
        }
    }
    /// The window frame is Liquid Glass, the color a tint on it: the step
    /// past the transparency wave's end (LookSlider). On a Mac without
    /// Liquid Glass it is kept and the window wears the color as before.
    var lookGlass: Bool {
        willSet { relay.send(\.lookGlass, newValue) }
        didSet { store.set(lookGlass, forKey: "backdrop.glass") }
    }

    /// Whether the window wears glass now: asked for, on a backdrop, and
    /// this Mac has it (WindowGlassPolicy).
    var wearsGlass: Bool {
        lookGlass && (backdrop != .none || edgeBackdrop) && WindowGlassPolicy.supported
    }

    /// Edge to edge with the column docked: the column stands on the
    /// window's own backdrop, as it does on a color, and only the page is
    /// laid differently, edge to edge rather than as a card. So a look,
    /// its glass and its shade, reads the same in either (#256). Put away,
    /// the column brought out is a card on a ground of its own, as on a
    /// color too.
    var edgeBackdrop: Bool {
        backdrop == .none && sidebar && !sideShut
    }

    /// Whether drawings lie over the window's color, or edge to edge the
    /// column's, now (LookDrawings).
    var wearsDrawings: Bool {
        backdrop != .site && LookDrawings.Set(rawValue: lookDrawings) != nil
    }

    /// How see-through the window's color is worn: on glass, as its tint.
    func wornTransparency(dark: Bool) -> Double {
        wearsGlass ? WindowGlassPolicy.transparency(for: swatch.color(dark: dark, custom: backdropColor)) : backdropTransparency
    }
    /// How strongly the drawings show, 0...1.
    var lookDrawingsStrength: Double {
        willSet { relay.send(\.lookDrawingsStrength, newValue) }
        didSet { store.set(lookDrawingsStrength, forKey: "backdrop.drawings.strength") }
    }
    /// The bookmarks in a row on the backdrop over the page. Off unless
    /// asked for, from Settings or with ⇧⌘B.
    var bookmarkBar: BookmarkBarMode {
        willSet { relay.send(\.bookmarkBar, newValue) }
        didSet { store.set(bookmarkBar.rawValue, forKey: "bookmarks.bar") }
    }
    /// What each bookmark in that row shows (BookmarkStyle).
    var bookmarkStyle: BookmarkStyle {
        willSet { relay.send(\.bookmarkStyle, newValue) }
        didSet { store.set(bookmarkStyle.rawValue, forKey: "bookmarks.style") }
    }
    /// Where a local page's errors and requests come out: under the page,
    /// or beside it (DevMode.swift). The last one chosen, for every page.
    var devSide: DevSide {
        willSet { relay.send(\.devSide, newValue) }
        didSet { store.set(devSide.rawValue, forKey: "dev.side") }
    }
    /// How a link that answers with JSON shows (JSONView.swift): Tree,
    /// Text or As Sent. The door's card and Settings › Developers both set it.
    var jsonView: JSONShow {
        willSet { relay.send(\.jsonView, newValue) }
        didSet { store.set(jsonView.rawValue, forKey: JSONShow.key) }
    }
    /// A local page whose server was never asked about asks, once, whether
    /// to turn Developer Mode on for it (Settings › Developers). On unless
    /// turned off.
    var offerDevMode: Bool {
        willSet { relay.send(\.offerDevMode, newValue) }
        didSet { store.set(offerDevMode, forKey: "dev.offer") }
    }
    /// Tabs nobody has looked at for four hours give their page back and
    /// keep where they were. On unless turned off.
    var sleepsTabs: Bool {
        willSet { relay.send(\.sleepsTabs, newValue) }
        didSet { store.set(sleepsTabs, forKey: "tabs.sleep") }
    }
    /// ⇧↩ opens the first search result directly.
    var instantLinks: Bool {
        willSet { relay.send(\.instantLinks, newValue) }
        didSet { store.set(instantLinks, forKey: "field.instant") }
    }
    /// Tabs nobody has looked at for this long are put away, the way Arc
    /// archives them. Twelve hours unless changed.
    var tidyAfter: Tidy {
        willSet { relay.send(\.tidyAfter, newValue) }
        didSet { store.set(tidyAfter.rawValue, forKey: "tabs.tidy") }
    }
    /// The ad blocker. On unless turned off; there is nothing else to it.
    var shielded: Bool {
        willSet { relay.send(\.shielded, newValue) }
        didSet { store.set(shielded, forKey: "shield") }
    }
    /// Private tabs get extensions too. Off unless asked for: a private tab
    /// keeps nothing, and some extensions watch what a page does.
    var extensionsInPrivate: Bool {
        willSet { relay.send(\.extensionsInPrivate, newValue) }
        didSet { store.set(extensionsInPrivate, forKey: "extensions.private") }
    }
    /// Whether the history keeps what pages said and what they looked like,
    /// so it can be searched by it. Kept on this Mac; off keeps only
    /// addresses and titles.
    var diaryText: Bool {
        willSet { relay.send(\.diaryText, newValue) }
        didSet { store.set(diaryText, forKey: "diary.text") }
    }
    /// The person's own switch, Settings › Passwords › Offer passkeys: on
    /// until they turn it off. Off sends sites to the password instead.
    /// Only this switch writes its key, and only where it can be turned.
    var passkeys: Bool {
        willSet { relay.send(\.passkeys, newValue) }
        didSet { store.set(passkeys, forKey: Self.passkeysKey) }
    }
    /// The switch's key, since 0.46.29. "passkeys" held the switch and also
    /// whether pages were offered them: every launch that couldn't do
    /// passkeys wrote false there (each build before 0.41.0's entitlement,
    /// any build without it), Sync carried that false to Macs that can, and
    /// their pages saw no PublicKeyCredential: Apple's sign-in asked for a
    /// newer browser (#1936, #1944). Nearly every false kept there was a
    /// machine's, not a choice, so the switch starts on again under a key
    /// nothing else writes; "passkeys" is left to older builds.
    nonisolated static let passkeysKey = "passkeys.offer"
    /// The switch as a store holds it: on unless turned off.
    nonisolated static func passkeysOn(in store: UserDefaults) -> Bool {
        store.object(forKey: passkeysKey) as? Bool ?? true
    }
    /// Whether pages are offered passkeys: the switch, on a Mac that can do
    /// them. Worked out each time, never kept (FormRelay.passkeysOffered).
    nonisolated static func offersPasskeys(in store: UserDefaults, possible: Bool) -> Bool {
        possible && passkeysOn(in: store)
    }
    /// Whether this build can actually do them: signed with the entitlement,
    /// its profile embedded. Fixed for the life of the process.
    let passkeysPossible: Bool

    /// Asked of the running process's own signature, which is the only thing
    /// that decides it, a profile file in the bundle proves nothing on its
    /// own, and an ad-hoc build has neither.
    nonisolated static var entitledToPasskeys: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil
        )
        return (value as? Bool) == true
    }
    var downloads: URL {
        willSet { relay.send(\.downloads, newValue) }
        didSet { store.set(downloads.path, forKey: "downloads") }
    }
    var asksWhereToSave: Bool {
        willSet { relay.send(\.asksWhereToSave, newValue) }
        didSet { store.set(asksWhereToSave, forKey: "downloads.ask") }
    }
    /// A page's file box opens the Mac's own panel, as in Arc, rather than
    /// the field's Files place (FormFiles reads the same key).
    var uploadsInFinder: Bool {
        willSet { relay.send(\.uploadsInFinder, newValue) }
        didSet { store.set(uploadsInFinder, forKey: "uploads.finder") }
    }
    /// Offer to keep a password the first time a site sees it.
    var savesPasswords: Bool {
        willSet { relay.send(\.savesPasswords, newValue) }
        didSet { store.set(savesPasswords, forKey: "passwords.save") }
    }
    /// Put a kept name and password into a sign-in as soon as one appears.
    var fillsPasswords: Bool {
        willSet { relay.send(\.fillsPasswords, newValue) }
        didSet { store.set(fillsPasswords, forKey: "passwords.fill") }
    }
    /// Settings › Passwords › Use Yab's passwords (`passwords.yab`, this
    /// Mac only). Off: Yab offers, fills and saves nothing, and agents
    /// don't use what it keeps; connected password managers still work.
    var usesYabPasswords: Bool {
        willSet { relay.send(\.usesYabPasswords, newValue) }
        didSet { store.set(usesYabPasswords, forKey: "passwords.yab") }
    }
    /// Who fills and saves here (PasswordManagers.Source).
    var passwordSource: PasswordManagers.Source {
        let saver = PasswordManagers.savingManager
        return PasswordManagers.Source(yab: usesYabPasswords, saver: saver,
                                       asksForApple: saver == PasswordManagers.apple && PasswordManagers.appleNative)
    }
    /// Offer the code a site mailed under the box that asks for it, read
    /// from Gmail with the tab's sign-in (MailCodes.swift).
    var codesFromMail: Bool {
        willSet { relay.send(\.codesFromMail, newValue) }
        didSet { store.set(codesFromMail, forKey: "codes.mail") }
    }
    /// The same for a code texted, read from Messages.
    var codesFromTexts: Bool {
        willSet { relay.send(\.codesFromTexts, newValue) }
        didSet { store.set(codesFromTexts, forKey: "codes.texts") }
    }
    /// Offer to keep a card or an address once a page takes it.
    var savesCards: Bool {
        willSet { relay.send(\.savesCards, newValue) }
        didSet { store.set(savesCards, forKey: "autofill.save") }
    }
    /// Hang the kept cards and addresses from the boxes they go in.
    var fillsCards: Bool {
        willSet { relay.send(\.fillsCards, newValue) }
        didSet { store.set(fillsCards, forKey: "autofill.fill") }
    }
    /// Offer to fill a whole form: the address, the profile, what was
    /// answered before (FormFill.on reads the same key).
    var fillsForms: Bool {
        willSet { relay.send(\.fillsForms, newValue) }
        didSet { store.set(fillsForms, forKey: "autofill.forms") }
    }
    /// Drafts for a form's questions, written by Claude (FormDraft.on).
    var draftsForms: Bool {
        willSet { relay.send(\.draftsForms, newValue) }
        didSet { store.set(draftsForms, forKey: "autofill.drafts") }
    }
    /// Touch ID, or the Mac's password, before a kept password goes into a
    /// page. Off unless asked for; Vault reads the same key.
    var provesToFill: Bool {
        willSet { relay.send(\.provesToFill, newValue) }
        didSet {
            store.set(provesToFill, forKey: Vault.proveKey)
            Vault.forgetProof(cancelling: false)
        }
    }
    /// The first launch has been walked through. Until then the welcome
    /// stands over the window.
    var welcomed: Bool {
        willSet { relay.send(\.welcomed, newValue) }
        didSet { store.set(welcomed, forKey: "welcomed") }
    }

    /// Where words that aren't an address are looked up. Google unless
    /// another is picked; `Engine` reads the file itself.
    var engine: Engine {
        willSet { relay.send(\.engine, newValue) }
        didSet { store.set(engine.rawValue, forKey: Engine.key) }
    }
    var searchSuggest: Bool {
        willSet { relay.send(\.searchSuggest, newValue) }
        didSet { store.set(searchSuggest, forKey: "search.suggest") }
    }
    /// A results page of your own, with `%s` for the words, for Other….
    var engineCustom: String {
        willSet { relay.send(\.engineCustom, newValue) }
        didSet { store.set(engineCustom, forKey: Engine.customKey) }
    }
    /// A site that says how it is searched is added as you visit it.
    var siteLearn: Bool {
        willSet { relay.send(\.siteLearn, newValue) }
        didSet { store.set(siteLearn, forKey: "scopes.learn"); Scopes.learning = siteLearn }
    }
    /// What was searched on a site before comes up under its field.
    var siteRecent: Bool {
        willSet { relay.send(\.siteRecent, newValue) }
        didSet { store.set(siteRecent, forKey: "scopes.recent"); Scopes.recalling = siteRecent }
    }

    /// ⌘Q has to be pressed twice, so a slip off ⌘W doesn't take the window
    /// with it. On unless turned off.
    var warnsOnQuit: Bool {
        willSet { relay.send(\.warnsOnQuit, newValue) }
        didSet { store.set(warnsOnQuit, forKey: "quit.warn") }
    }

    /// A link from another app comes up in a small window of its own, to
    /// read and close or keep (LinkWindow). On unless turned off.
    var smallLinks: Bool {
        willSet { relay.send(\.smallLinks, newValue) }
        didSet { store.set(smallLinks, forKey: LinkWindow.key) }
    }

    /// ⌥⌘N, in any app, brings up an empty small window to type into, as
    /// Little Arc's key does. On unless turned off: taken for the whole Mac,
    /// the keys stop reaching the app in front, which may want them.
    var smallKey: Bool {
        willSet { relay.send(\.smallKey, newValue) }
        didSet {
            store.set(smallKey, forKey: LinkWindow.hotkeyKey)
            LinkWindow.hotkey(smallKey)
        }
    }

    /// A link shift-clicked comes up in a panel over the page (LinkPeek.swift).
    /// On unless turned off.
    var peeks: Bool {
        willSet { relay.send(\.peeks, newValue) }
        didSet { store.set(peeks, forKey: "peek") }
    }
    /// A rested link's card, with a summary on this Mac when available.
    var linkPreviews: Bool {
        willSet { relay.send(\.linkPreviews, newValue) }
        didSet { store.set(linkPreviews, forKey: LinkCard.key) }
    }
    /// Sets of tabs in the one window (Spaces.swift). Off unless turned on.
    var usesSpaces: Bool {
        willSet { relay.send(\.usesSpaces, newValue) }
        didSet { store.set(usesSpaces, forKey: "spaces") }
    }
    /// Live folders are optional; turning them off keeps every folder and
    /// tab, and pauses source reads and routine-to-folder updates.
    var usesLiveFolders: Bool {
        willSet { relay.send(\.usesLiveFolders, newValue) }
        didSet {
            guard usesLiveFolders != oldValue else { return }
            store.set(usesLiveFolders, forKey: LiveFolderFeature.key)
            for browser in BrowserWindows.shared.browsers where browser.prefs.usesLiveFolders != usesLiveFolders {
                browser.prefs.usesLiveFolders = usesLiveFolders
            }
            LiveFolders.shared.availabilityChanged()
        }
    }
    /// Pins: In Every Space, one row of pins every space that shares
    /// sign-ins shows, or In Each Space, a row of its own in each
    /// (SharedPins.swift). Every window follows the one it was set in.
    var pinsEverySpace: Bool {
        willSet { relay.send(\.pinsEverySpace, newValue) }
        didSet {
            SharedPins.chose(pinsEverySpace, settings: store)
            for browser in BrowserWindows.shared.browsers where browser.prefs.pinsEverySpace != pinsEverySpace {
                browser.prefs.pinsEverySpace = pinsEverySpace
            }
        }
    }
    /// Mail as a tab of yab's own (docs/mail.md): off until turned on.
    var usesMail: Bool {
        willSet { relay.send(\.usesMail, newValue) }
        didSet {
            store.set(usesMail, forKey: "mail")
            store.set(usesMail, forKey: MailExperiment.key)
            MailCenter.shared.turn(usesMail)
            if !usesMail && oldValue {
                for browser in BrowserWindows.shared.browsers { browser.hideMail() }
            }
            for browser in BrowserWindows.shared.browsers where browser.prefs.usesMail != usesMail {
                browser.prefs.usesMail = usesMail
            }
        }
    }
    /// Mail's motion, Settings › Mail's Animations: on unless turned off,
    /// and off, mail holds still as under Reduce Motion (MailDesk.still).
    var mailAnimations: Bool {
        willSet { relay.send(\.mailAnimations, newValue) }
        didSet { store.set(mailAnimations, forKey: "mail.motion") }
    }
    /// Words that read as one thing to do somewhere known get a row of
    /// their own in the field, with what is known of it beside the list
    /// (FieldRequest.swift). Experimental, off until turned on.
    var fieldRequests: Bool {
        willSet { relay.send(\.fieldRequests, newValue) }
        didSet { store.set(fieldRequests, forKey: FieldRequest.key) }
    }
    /// Expanded menu catalog and exact-name ranking. Experimental, opt in.
    var menuCommands: Bool {
        willSet { relay.send(\.menuCommands, newValue) }
        didSet {
            guard menuCommands != oldValue else { return }
            store.set(menuCommands, forKey: MenuCommands.key)
            for browser in BrowserWindows.shared.browsers {
                if browser.prefs !== self && browser.prefs.menuCommands != menuCommands {
                    browser.prefs.menuCommands = menuCommands
                }
                if browser.fieldShowing { browser.guessAgain() }
            }
        }
    }
    /// The tabs a routine or an agent from the terminal opens for itself
    /// stand behind one row over the column's foot rather than among yours
    /// (AgentRow.swift). On until turned off.
    var agentRow: Bool {
        willSet { relay.send(\.agentRow, newValue) }
        didSet {
            guard agentRow != oldValue else { return }
            store.set(agentRow, forKey: AgentRow.key)
            for browser in BrowserWindows.shared.browsers where browser.prefs !== self && browser.prefs.agentRow != agentRow {
                browser.prefs.agentRow = agentRow
            }
            for browser in BrowserWindows.shared.browsers { browser.folderBook.refresh() }
        }
    }

    /// A video playing on a video site comes out into the floating window
    /// when you go to another tab (Browser.leaving). On unless turned off.
    /// What plays in a tab you aren't on, over the sidebar's foot (the
    /// island, PlayerBand.swift). On unless turned off, here or from its
    /// own menu.
    var showsPlayer: Bool {
        willSet { relay.send(\.showsPlayer, newValue) }
        didSet { store.set(showsPlayer, forKey: "player.shown") }
    }
    var floatsOnLeave: Bool {
        willSet { relay.send(\.floatsOnLeave, newValue) }
        didSet { store.set(floatsOnLeave, forKey: "float.leave") }
    }
    /// A ⌘-click or a middle click on a link makes a folder of today's of
    /// the page and the tab it opened, as Dia's auto groups do (Research.swift,
    /// docs/link-folders.md). On unless turned off, as in Dia (the user's
    /// call, 2026-10-16); off, the link goes after the page as in Arc.
    var linkFolders: Bool {
        willSet { relay.send(\.linkFolders, newValue) }
        didSet {
            store.set(linkFolders, forKey: "tabs.linkFolders")
            for browser in BrowserWindows.shared.browsers where browser.prefs !== self && browser.prefs.linkFolders != linkFolders {
                browser.prefs.linkFolders = linkFolders
            }
        }
    }
    /// An emoji for a ⌘-click folder of pages of more than one site, from
    /// the same answer as its name, as Dia's "Add emoji to new tab groups"
    /// (LinkFolders). On unless turned off, as in the user's Dia.
    var folderEmoji: Bool {
        willSet { relay.send(\.folderEmoji, newValue) }
        didSet { store.set(folderEmoji, forKey: "tabs.folderEmoji") }
    }
    /// ⌥⇧-click on a tab's row puts it in a folder with the tab in front,
    /// as Dia's "⌥-⇧-click opens tab in group" (Browser.groupClick). Off,
    /// ⌥⇧ picks the run as ⇧ does. On unless turned off, as in the user's Dia.
    var optShiftFolders: Bool {
        willSet { relay.send(\.optShiftFolders, newValue) }
        didSet { store.set(optShiftFolders, forKey: "tabs.optShiftFolders") }
    }
    /// Joining a meeting puts its call in a folder named for it, with the
    /// time left, as Dia's "Automatically group tabs for meetings"
    /// (MeetingFolders). On unless turned off, as in the user's Dia.
    var meetingFolders: Bool {
        willSet { relay.send(\.meetingFolders, newValue) }
        didSet { store.set(meetingFolders, forKey: "tabs.meetingFolders") }
    }
    /// Today's tabs in every window of their space, as in Arc (feedback
    /// #340, KeptEverywhere.swift); off, each window's own, as in Dia.
    /// Off unless turned on, so windows in use stay as they are.
    var todayEveryWindow: Bool {
        willSet { relay.send(\.todayEveryWindow, newValue) }
        didSet {
            guard todayEveryWindow != oldValue else { return }
            store.set(todayEveryWindow, forKey: KeptEverywhere.todayKey)
            for browser in BrowserWindows.shared.browsers where browser.prefs.todayEveryWindow != todayEveryWindow {
                browser.prefs.todayEveryWindow = todayEveryWindow
            }
            KeptEverywhere.turnToday(todayEveryWindow)
        }
    }
    /// The same when another app comes to the front, and back into its tab
    /// when yab does (Browser.appLeft). Off unless asked for.
    var floatsAway: Bool {
        willSet { relay.send(\.floatsAway, newValue) }
        didSet { store.set(floatsAway, forKey: "float.away") }
    }
    init() {
        // Glass from Settings › Experimental, put in the looks first.
        Spaces.glazeOnce()
        showsPlayer = store.object(forKey: "player.shown") as? Bool ?? true
        floatsOnLeave = store.object(forKey: "float.leave") as? Bool ?? true
        floatsAway = store.bool(forKey: "float.away")
        linkFolders = store.object(forKey: "tabs.linkFolders") as? Bool ?? true
        folderEmoji = store.object(forKey: "tabs.folderEmoji") as? Bool ?? true
        optShiftFolders = store.object(forKey: "tabs.optShiftFolders") as? Bool ?? true
        meetingFolders = store.object(forKey: "tabs.meetingFolders") as? Bool ?? true
        todayEveryWindow = store.bool(forKey: KeptEverywhere.todayKey)
        warnsOnQuit = store.object(forKey: "quit.warn") as? Bool ?? true
        smallLinks = LinkWindow.wanted
        smallKey = LinkWindow.keyWanted(in: store)
        peeks = store.object(forKey: "peek") as? Bool ?? true
        linkPreviews = store.object(forKey: LinkCard.key) as? Bool ?? true
        usesSpaces = Spaces.on(settings: store, kept: Store.file("spaces.json"))
        usesLiveFolders = LiveFolderFeature.initial(in: store, folder: Store.file("empty-folders.json").deletingLastPathComponent())
        usesMail = MailExperiment.enabled(in: store)
        mailAnimations = store.object(forKey: "mail.motion") as? Bool ?? true
        fieldRequests = store.bool(forKey: FieldRequest.key)
        menuCommands = store.bool(forKey: MenuCommands.key)
        agentRow = store.object(forKey: AgentRow.key) as? Bool ?? true
        engine = Engine.current
        engineCustom = Engine.customTemplate
        searchSuggest = store.object(forKey: "search.suggest") as? Bool ?? true
        let learn = store.object(forKey: "scopes.learn") as? Bool ?? true
        let recent = store.object(forKey: "scopes.recent") as? Bool ?? true
        siteLearn = learn
        siteRecent = recent
        Scopes.learning = learn
        Scopes.recalling = recent
        // Carried over from when there were four ways of holding the browser
        // and this was one of them.
        bench = store.bool(forKey: "bench")
        agentsRemember = !store.bool(forKey: "agents.forget")
        aiUse = AIUse.level(in: store)
        aiRowsHidden = AIUse.rowsHidden(in: store)
        tidyTabs = store.object(forKey: "tidy.tabs") as? Bool ?? true
        let titles = store.object(forKey: "tidy.titles") as? Bool ?? true
        tidyTitles = titles
        ShortNames.enabled = titles && AIUse.allows(.background, in: store)
        folderNames = store.object(forKey: "folders.names") as? Bool ?? true
        tidyDownloads = store.object(forKey: "tidy.downloads") as? Bool ?? false
        // From the two choices there were before: Send allowed was Bypass,
        // asking first in your tabs (or reading them only) was Ask. A
        // build that isn't shipped starts at Bypass, so trying agents
        // there is never held up by a yes.
        agentsAsking = store.string(forKey: "agents.asking").flatMap(AgentAsking.init)
            ?? (store.bool(forKey: "agents.commit-freely") || Store.testing || Store.development ? .bypass
                : ["ask", "read"].contains(store.string(forKey: "agents.tabs") ?? "") ? .ask : .auto)
        agentsMessages = store.bool(forKey: "agents.messages")
        agentsAskElsewhere = store.object(forKey: "agents.ask-elsewhere") as? Bool ?? true
        agentsAskSound = store.object(forKey: "agents.ask-sound") as? Bool ?? true
        agentTabsAfter = AgentTabsAfter.saved
        askOpens = store.string(forKey: "agents.askOpens").flatMap(AskOpens.init) ?? .chat
        // The Mac's own unless one was picked, as every Mac app is: Light
        // out of the box left a dark Mac with a light browser that seemed
        // stuck (register 1284). A Light or Dark picked is kept.
        let chosen = store.string(forKey: "look").flatMap(Look.init) ?? .system
        look = chosen
        // Before the first window, and not deferred: the window that is about
        // to be made should be made in the right appearance. Through `shared`,
        // not `NSApp`: on macOS 14 SwiftUI makes this before the application,
        // and `NSApp` is still nil here.
        let application = NSApplication.shared
        let appearance = chosen.appearance
        // A new window reads the same global choice. Assigning it again
        // invalidates every existing window's appearance and view tree.
        if application.appearance?.name != appearance?.name {
            application.appearance = appearance
        }
        // The key once held the swatch itself, with "none" for edge to edge:
        // a swatch there is a window painted in it, and the swatch it was.
        let kept = Self.american(store.string(forKey: "backdrop"))
        let mode = kept.flatMap(Backdrop.init) ?? (kept == nil ? .site : .color)
        let painted = Self.american(store.string(forKey: "backdrop.swatch")).flatMap(Swatch.init)
            ?? kept.flatMap(Swatch.init) ?? .gray
        // Written again in today's spelling, once read.
        store.set(mode.rawValue, forKey: "backdrop")
        store.set(painted.rawValue, forKey: "backdrop.swatch")
        backdrop = mode
        swatch = painted
        backdropTransparency = BackdropTransparency.clamp(store.double(forKey: "backdrop.transparency"))
        backdropColor = store.string(forKey: "backdrop.color").flatMap(NSColor.init(hex:))
            ?? NSColor(hex: "E3E3E5")!
        grain = store.object(forKey: "backdrop.grain.amount") as? Double
            ?? ((store.object(forKey: "backdrop.grain") as? Bool ?? true) ? Grain.standard : 0)
        sidebar = store.object(forKey: "sidebar") as? Bool
            ?? (store.string(forKey: "manner") == "side")
        sideShut = store.bool(forKey: "sidebar.shut")
        sidebarButton = store.object(forKey: "sidebar.button") as? Bool ?? true
        sideReveal = store.string(forKey: SideReveal.key).flatMap(SideReveal.init) ?? .moment
        stripShut = store.bool(forKey: "strip.shut")
        spaceDots = store.bool(forKey: "spaces.dots")
        spaceNames = store.object(forKey: "spaces.names") as? Bool ?? true
        compactField = store.bool(forKey: "field.compact")
        sideFlank = store.string(forKey: "sidebar.flank").flatMap(Flank.init) ?? .left
        addressBar = store.bool(forKey: "addressbar")
        peekAddress = store.bool(forKey: "peek.address")
        fullURL = store.bool(forKey: "addressbar.full-url")
        pageZoom = PageAppearance.defaultZoom(in: store)
        pageFonts = PageFonts.read(in: store)
        darkPages = DarkMode.read(in: store)
        darkLook = DarkLook.read(in: store)
        backdropColors = ArcSidebar.repaired((store.stringArray(forKey: "backdrop.colors") ?? []).filter { NSColor(hex: $0) != nil })
        lookShift = store.bool(forKey: "backdrop.shift")
        lookSite = store.bool(forKey: "backdrop.site-tint")
        lookDrawings = LookDrawings.Set(rawValue: store.string(forKey: "backdrop.drawings") ?? "")?.rawValue ?? ""
        lookMode = LookMode(rawValue: store.string(forKey: "backdrop.mode") ?? "")?.rawValue ?? ""
        lookGlass = store.bool(forKey: "backdrop.glass")
        lookDrawingsStrength = store.object(forKey: "backdrop.drawings.strength") == nil ? LookDrawings.standard
            : min(1, max(0, store.double(forKey: "backdrop.drawings.strength")))
        bookmarkBar = store.string(forKey: "bookmarks.bar").flatMap(BookmarkBarMode.init) ?? .never
        bookmarkStyle = store.string(forKey: "bookmarks.style").flatMap(BookmarkStyle.init) ?? .names
        // Beside the page on a wide screen, where the page keeps its height;
        // under it otherwise.
        devSide = store.string(forKey: "dev.side").flatMap(DevSide.init)
            ?? ((NSScreen.main?.visibleFrame.width ?? 0) > 1400 ? .right : .bottom)
        offerDevMode = store.object(forKey: "dev.offer") as? Bool ?? true
        jsonView = store.string(forKey: JSONShow.key).flatMap(JSONShow.init) ?? .tree
        let width = store.object(forKey: "sidebar.width") as? Double ?? Double(Metrics.side)
        sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, CGFloat(width)))
        // Site icons for everyone. The old "glyph" key held letters for most,
        // picked in a welcome that no longer asks, so it is left unread.
        glyph = store.string(forKey: "tabs.glyph").flatMap(Glyph.init) ?? .icons
        density = Density.saved
        // Off unless turned on: memory running
        // out puts tabs down whatever this says (Sleep.swift).
        sleepsTabs = store.object(forKey: "tabs.sleep") as? Bool ?? false
        instantLinks = store.object(forKey: "field.instant") as? Bool ?? true
        tidyAfter = (store.object(forKey: "tabs.tidy") as? Int).flatMap(Tidy.init) ?? .halfDay
        shielded = store.object(forKey: "shield") as? Bool ?? true
        extensionsInPrivate = store.bool(forKey: "extensions.private")
        diaryText = store.object(forKey: "diary.text") as? Bool ?? true
        // Offered only in a build that can actually do them, one with
        // Apple's browser entitlement and its profile embedded; the switch
        // is the person's, on until they turn it off (passkeysKey). Nothing
        // is written here: a launch that can't do them leaves the switch as
        // it found it, for this Mac and every other.
        passkeysPossible = Preferences.entitledToPasskeys
        passkeys = Self.passkeysOn(in: store)
        // A test run downloads into its own folder: ~/Downloads would have
        // macOS stop it to ask for access, with a dialog on the screen of
        // whoever is working beside it.
        let testDownloads = Store.folder.appendingPathComponent("Downloads", isDirectory: true)
        if Store.testing { try? FileManager.default.createDirectory(at: testDownloads, withIntermediateDirectories: true) }
        downloads = Store.testing
            ? testDownloads
            : (store.string(forKey: "downloads")).map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        asksWhereToSave = store.bool(forKey: "downloads.ask")
        uploadsInFinder = store.bool(forKey: "uploads.finder")
        savesPasswords = store.object(forKey: "passwords.save") as? Bool ?? true
        fillsPasswords = store.object(forKey: "passwords.fill") as? Bool ?? true
        usesYabPasswords = store.object(forKey: "passwords.yab") as? Bool ?? true
        codesFromMail = store.bool(forKey: "codes.mail")
        codesFromTexts = store.bool(forKey: "codes.texts")
        provesToFill = store.bool(forKey: Vault.proveKey)
        savesCards = store.object(forKey: "autofill.save") as? Bool ?? true
        fillsCards = store.object(forKey: "autofill.fill") as? Bool ?? true
        fillsForms = store.object(forKey: "autofill.forms") as? Bool ?? true
        draftsForms = store.object(forKey: "autofill.drafts") as? Bool ?? true
        // Anyone who already has a session was here before the welcome
        // existed; they are not asked to sit through it.
        welcomed = store.bool(forKey: "welcomed") || store.object(forKey: "glyph") != nil
        // In Every Space for a new Mac, In Each Space for one in use before:
        // decided once, at the first launch, and written down.
        pinsEverySpace = SharedPins.decide(settings: store, folder: Store.folder)
        // Before the first web view exists: WebKit reads these once.
        Preferences.tellWebKit()
        // Left behind by an assistant this browser no longer has, and by
        // Autocorrect, which is macOS's own setting now.
        for key in ["mind.model", "mind.effort", "mind.acting", "mind.width", "mind.open", "autocorrect"] {
            store.removeObject(forKey: key)
        }
        displayWatch = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.objectWillChange.send() }
            }
    }

    /// WebKit's text checker takes its orders from the app's standard
    /// defaults, the real ones, not the test suite, because it is WebKit
    /// reading them and not us. Autocorrect and text replacements follow
    /// Keyboard › Text Input: autocorrect only while macOS
    /// has "Correct spelling automatically" on, and never when any of its
    /// switches says off (register 407); Text Replacements while macOS
    /// has them on (feedback 339). Both are written down rather than left
    /// unset, so an old value the Edit menu left behind can't win. Smart
    /// quotes and dashes go off outright: in a browser they are wrong in
    /// every code field and wanted in almost none.
    static func tellWebKit() {
        let defaults = UserDefaults.standard
        let global = defaults.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        defaults.set(macOSSays(defaults.object(forKey: "NSAutomaticSpellingCorrectionEnabled"),
                               global["WebAutomaticSpellingCorrectionEnabled"],
                               checker: NSSpellChecker.isAutomaticSpellingCorrectionEnabled),
                     forKey: "WebAutomaticSpellingCorrectionEnabled")
        defaults.set(macOSSays(defaults.object(forKey: "NSAutomaticTextReplacementEnabled"),
                               global["WebAutomaticTextReplacementEnabled"],
                               checker: NSSpellChecker.isAutomaticTextReplacementEnabled),
                     forKey: "WebAutomaticTextReplacementEnabled")
        defaults.set(false, forKey: "WebAutomaticQuoteSubstitutionEnabled")
        defaults.set(false, forKey: "WebAutomaticDashSubstitutionEnabled")
    }

    /// On only while NSSpellChecker says so and neither macOS's own switch
    /// (as this app reads it: its domain, then the global one) nor the
    /// global Web one says off.
    static func macOSSays(_ setting: Any?, _ webSetting: Any?, checker: Bool) -> Bool {
        func off(_ value: Any?) -> Bool {
            if let number = value as? NSNumber { return !number.boolValue }
            if let text = value as? String { return ["no", "false", "0"].contains(text.lowercased()) }
            return false
        }
        return checker && !off(setting) && !off(webSetting)
    }
}

extension Preferences {
    /// Codes from mail as they stand: as the switch was set, else on once
    /// Mail has an account, since connecting it is asking for them; off
    /// without Mail, where reading Gmail's list with a site's sign-in is
    /// for the person to turn on.
    var mailCodes: Bool {
        get { store.object(forKey: "codes.mail") == nil ? usesMail && !MailCenter.shared.accounts.isEmpty : codesFromMail }
        set { codesFromMail = newValue }
    }

    /// Texted codes as they stand: as the switch was set, else on only
    /// where Messages can already be read. Full Disk Access is never asked
    /// for on the way; without it they stay off until turned on.
    var textCodes: Bool {
        get { store.object(forKey: "codes.texts") == nil ? MailCodes.textsReadable : codesFromTexts }
        set { codesFromTexts = newValue }
    }
}
