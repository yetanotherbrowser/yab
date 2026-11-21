import AppKit
import SwiftUI
import SyncKit
import WebKit

// Spaces: sets of tabs in the one window, each with its own row, and signed
// in where the others are unless it was made to start afresh with cookies of
// its own. Its pins are its own, or, with Pins at In Every Space, the one row
// every space signed in where the others are shares (SharedPins.swift).
//
// Off unless turned on in Settings › Tabs. Until then there is one space,
// the first, and nothing about it shows: its tabs are the session there
// always was and its sites use the store there always was, so turning
// spaces on signs nobody out.
//
// Switching swaps the row: the tabs left behind are parked as they are,
// sound and all, and sleep after half an hour as any tab does, pins too.
// ⌃1 to ⌃9 switch, the space's icon at the foot of the column or the head of
// the strip opens its menu, and two fingers sideways over the column go to
// the next one or back.
//
// A local agent's tabs are not any space's row: a task runs on in whichever
// space is on screen, and its folder is there with it. Where it signs in is
// its own choice, made when it opens a tab: the space whose sign-ins it
// needs (`spaces` and `open` in Mcp.swift), since two spaces can be signed
// in as two different people. Cloud assistants' tabs belong to the space
// the user granted them, even when its sign-ins are shared.

struct Space: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Its emoji or the name of the symbol picked from the Icon tab.
    var icon: String
    /// Cookies and sign-ins of its own, rather than the first space's.
    var ownSignIns: Bool
    /// The window's color and grain while it is on screen. Nil for a space
    /// made before spaces had their own, until it is first left: it keeps
    /// what the window wore then.
    var paint: SpacePaint? = nil
    /// The other browser's place it was brought in from, "Arc:<id>",
    /// "Chrome:Profile 1", so bringing it in again finds it by that and
    /// not by a name that may have changed (Browser.bring).
    var origin: String? = nil
    /// Every page ever brought into it, by TabImport.key: bringing in
    /// again brings only what is new there, not a pin you took out here.
    var brought: [String]? = nil
    /// For a space with sign-ins of its own brought in from a profile:
    /// that profile, "Arc:Profile 1", whose cookies bringing sign-ins in
    /// puts in this space's store rather than the shared one.
    var signedInAs: String? = nil
    /// The space whose sign-ins, store and extensions this one uses, for a
    /// second space of one profile of the other browser: Arc's spaces of a
    /// profile share all that, and two stores here were two strangers
    /// (row 1752). That space may be deleted since; the store stays while
    /// a space uses it. Nil for a space that is its own (Spaces.link).
    var signInWith: UUID? = nil
    /// Sites muted in it, "youtube.com", Dia's domain-wide muting: every
    /// tab of one, open or opened later, until it is let back in from any
    /// of them (Browser.toggleSiteMute). Nil for none.
    var mutedSites: [String]? = nil
    /// The engine the field searches with in it, an Engine's raw value
    /// (EngineChoice.space). Nil for Settings › Search's, the default.
    var search: String? = nil
    /// Its results page, with `%s` for the words, while `search` is Other….
    var searchCustom: String? = nil
    /// The exact icon last deliberately picked here or on a newer device.
    /// Old devices may echo a symbol's emoji without making that choice;
    /// a matching value in sync distinguishes a real emoji pick from it.
    var iconChoice: String? = nil
    /// Each deliberate pick gets its own identity, even when it repeats
    /// the same icon. Sync must observe that choice as a new value too.
    var iconChoiceID: String? = nil

    mutating func chooseIcon(_ icon: String) {
        self.icon = icon
        iconChoice = icon
        iconChoiceID = UUID().uuidString
    }

    /// What the field searches with in it.
    var engine: EngineChoice { EngineChoice.space(search, custom: searchCustom) }

    /// Its emoji on its color, both looks', for the well of a question about
    /// it (Question.space); in the window's color while it has none of its own.
    @MainActor func well(_ prefs: Preferences) -> SpaceWell {
        let paint = paint ?? SpacePaint(prefs)
        return SpaceWell(emoji: icon, light: paint.color(dark: false), dark: paint.color(dark: true))
    }

    /// The first space: the session and the store there were before spaces.
    static let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var isFirst: Bool { id == Space.firstID }

    /// Stable logical profile identity; its Space may have been deleted.
    var profileID: UUID { ownSignIns ? signInWith ?? id : Self.firstID }

    static func ownProfile(for space: Space, among spaces: [Space], fresh: UUID = UUID()) -> UUID {
        spaces.contains { $0.id != space.id && $0.profileID == space.profileID } ? fresh : space.profileID
    }
}

/// What a space paints the window in: one of the swatches or a color of
/// your own, and the grain over it or not. Worn through the preferences,
/// so the window, Settings and its picture of the window all read it
/// where they always have.
struct SpacePaint: Codable, Equatable {
    var swatch: String
    /// Your own color, kept even while a swatch is picked.
    var color: String
    /// How much grain, 0 for none (Grain).
    var grain: Double
    var colors: [String]
    var transparency: Double
    /// The colors turn a step with each new tab (LookCard).
    var shift = false
    /// A page with a color of its own tints one of yours (LookCard).
    var site = false
    /// Drawings over the color, LookDrawings.Set's raw value, "" for none.
    var drawings = ""
    /// How strongly they show.
    var drawingsStrength = LookDrawings.standard
    /// Its own light or dark, LookMode's raw value, "" to go with Appearance.
    var mode = ""
    /// The window frame is Liquid Glass, the color a tint on it: the step
    /// past the transparency wave's end. `transparency` is kept for the way
    /// back.
    var glass = false

    init(swatch: Swatch, color: NSColor, grain: Double, colors: [String] = [], transparency: Double = 0,
         shift: Bool = false, site: Bool = false, drawings: String = "", drawingsStrength: Double = LookDrawings.standard,
         mode: String = "", glass: Bool = false) {
        self.swatch = swatch.rawValue
        self.color = color.hex
        self.grain = grain
        self.transparency = BackdropTransparency.clamp(transparency)
        self.colors = colors.filter { NSColor(hex: $0) != nil }
        self.shift = shift
        self.site = site
        self.drawings = LookDrawings.Set(rawValue: drawings)?.rawValue ?? ""
        self.drawingsStrength = min(1, max(0, drawingsStrength))
        self.mode = LookMode(rawValue: mode)?.rawValue ?? ""
        self.glass = glass
    }

    // Grain was on or off before it had an amount, and a build from then
    // reads this file too: "grain" stays on or off, the amount goes beside.
    // What the look card added is written only when it isn't the default,
    // so a space that never used it reads as it always did.
    private enum CodingKeys: String, CodingKey { case swatch, color, grain, grainAmount, colors, transparency, shift, site, drawings, drawingsStrength, mode, glass }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        swatch = try c.decode(String.self, forKey: .swatch)
        color = try c.decode(String.self, forKey: .color)
        transparency = BackdropTransparency.clamp(try c.decodeIfPresent(Double.self, forKey: .transparency) ?? 0)
        let on = try c.decodeIfPresent(Bool.self, forKey: .grain) ?? false
        grain = try c.decodeIfPresent(Double.self, forKey: .grainAmount) ?? (on ? Grain.standard : 0)
        colors = ArcSidebar.repaired((try c.decodeIfPresent([String].self, forKey: .colors) ?? []).filter { NSColor(hex: $0) != nil })
        shift = try c.decodeIfPresent(Bool.self, forKey: .shift) ?? false
        site = try c.decodeIfPresent(Bool.self, forKey: .site) ?? false
        drawings = LookDrawings.Set(rawValue: try c.decodeIfPresent(String.self, forKey: .drawings) ?? "")?.rawValue ?? ""
        drawingsStrength = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .drawingsStrength) ?? LookDrawings.standard))
        mode = LookMode(rawValue: try c.decodeIfPresent(String.self, forKey: .mode) ?? "")?.rawValue ?? ""
        glass = try c.decodeIfPresent(Bool.self, forKey: .glass) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(swatch, forKey: .swatch)
        try c.encode(color, forKey: .color)
        try c.encode(grain > 0, forKey: .grain)
        try c.encode(grain, forKey: .grainAmount)
        try c.encode(transparency, forKey: .transparency)
        if !colors.isEmpty { try c.encode(colors, forKey: .colors) }
        if shift { try c.encode(shift, forKey: .shift) }
        if site { try c.encode(site, forKey: .site) }
        if !drawings.isEmpty { try c.encode(drawings, forKey: .drawings) }
        if drawingsStrength != LookDrawings.standard { try c.encode(drawingsStrength, forKey: .drawingsStrength) }
        if !mode.isEmpty { try c.encode(mode, forKey: .mode) }
        if glass { try c.encode(glass, forKey: .glass) }
    }

    @MainActor init(_ prefs: Preferences) {
        self.init(swatch: prefs.swatch, color: prefs.backdropColor, grain: prefs.grain, colors: prefs.backdropColors, transparency: prefs.backdropTransparency,
                  shift: prefs.lookShift, site: prefs.lookSite, drawings: prefs.lookDrawings, drawingsStrength: prefs.lookDrawingsStrength,
                  mode: prefs.lookMode, glass: prefs.lookGlass)
    }

    var picked: Swatch { Swatch(rawValue: swatch) ?? .gray }
    var own: NSColor { NSColor(hex: color) ?? NSColor(srgbRed: 0.5, green: 0.72, blue: 0.64, alpha: 1) }

    /// The window's color for this brightness.
    func color(dark: Bool) -> NSColor { picked.color(dark: dark, custom: own) }

    /// No color: white or black with the window, its own color white and
    /// no linked ones, so nothing tints it.
    mutating func wearPlain() {
        swatch = Swatch.plain.rawValue
        color = Swatch.plainSeed
        colors = []
    }

    /// How see-through its color is worn: on glass, as the glass's tint
    /// (WindowGlassPolicy), on a Mac that has it.
    func wornTransparency(dark: Bool) -> Double {
        glass && WindowGlassPolicy.supported ? WindowGlassPolicy.transparency(for: color(dark: dark)) : transparency
    }

    func gradient(dark: Bool) -> [Color] {
        colors.compactMap(NSColor.init(hex:)).map { Color(nsColor: dark ? $0.deepened : $0) }
    }

    @MainActor func wear(_ prefs: Preferences) {
        if prefs.swatch != picked { prefs.swatch = picked }
        if prefs.backdropColor.hex != color { prefs.backdropColor = own }
        if prefs.backdropTransparency != transparency { prefs.backdropTransparency = transparency }
        if prefs.grain != grain { prefs.grain = grain }
        if prefs.backdropColors != colors { prefs.backdropColors = colors }
        if prefs.lookShift != shift { prefs.lookShift = shift }
        if prefs.lookSite != site { prefs.lookSite = site }
        if prefs.lookDrawings != drawings { prefs.lookDrawings = drawings }
        if prefs.lookDrawingsStrength != drawingsStrength { prefs.lookDrawingsStrength = drawingsStrength }
        if prefs.lookMode != mode { prefs.lookMode = mode }
        if prefs.lookGlass != glass { prefs.lookGlass = glass }
    }
}

/// A space's emoji, at the size a symbol would be, or its symbol
/// (SpaceSymbols) in the ink around it.
struct SpaceMark: View {
    let icon: String
    var size: CGFloat

    var body: some View {
        if Spaces.isEmoji(icon) {
            Text(icon).font(.system(size: size + 1))
        } else if let art = SpaceIconArt.art(icon) {
            Image(nsImage: art).renderingMode(.template).resizable()
                .frame(width: size, height: size)
                .accessibilityLabel(Text(SpaceIconArt.catalog[icon]?.arc ?? icon))
        } else {
            Image(systemName: icon).font(.system(size: size, weight: .medium))
        }
    }
}

extension Space {
    /// Its name for words only, a menu's or a list's: after its emoji, or
    /// alone when it wears a symbol, which words can't hold.
    func marked(_ gap: String = " ") -> String {
        Spaces.isEmoji(icon) ? icon + gap + name : name
    }
}

/// Tabs sent to another space, kept for Undo.
struct SpaceMove {
    struct Moved {
        /// The tab as it was in the row it left.
        let original: Tab.ID
        /// The tab as it is in the other space: the same one, or its page
        /// opened afresh there.
        let now: Tab
        /// Where it stood in the row it left.
        let at: Int
    }
    let from: UUID
    let to: UUID
    let wasActive: Tab.ID?
    let tabs: [Moved]
    /// Folders that went whole out of a folder that stayed, and the one
    /// each was in; tabs that left their folder behind, by `original`, and
    /// the folder each was in; empty folders gone with their folder.
    var cuts: [(nest: Nest, parent: Nest)] = []
    var unnested: [Tab.ID: Nest] = [:]
    var empties: [Nest] = []
    /// Tabs an agent was at work in, by `original`: the home an agent's
    /// own had before (nil for none), and nil for a tab of yours, which
    /// went along with you before it was sent.
    var homes: [Tab.ID: UUID?] = [:]
}

/// A space's row of tabs while another space is on screen.
struct Parked {
    var tabs: [Tab]
    var active: Tab.ID?
    /// Its tabs side by side (Split.swift), parked with them.
    var pairs: [Pair] = []
    /// The shared pins parked (SharedPins.swift): the order they all stand
    /// in, one gone along with a call among them.
    var order: [Tab.ID]? = nil
    /// A row read from a file left on one of the shared pins: which, by its
    /// place among them.
    var sharedFront: Int? = nil
    /// Read for a window with no row of its own there yet: only the
    /// space's kept tabs and pins, every window's (KeptEverywhere.swift),
    /// none of them in front.
    var fresh = false
}

@MainActor
enum Spaces {
    static let changed = Notification.Name("yab.spaces.changed")
    /// What a space made without the tray wears, the first no space wears
    /// yet: an import's groups, the bench.
    static let icons = ["🏠", "💼", "🌱", "🧪", "🛍️", "✈️", "📚", "🎨", "🎧", "💡", "🚀", "🧭", "☕️", "🎯"]

    /// The symbols spaces wore before they were emoji, and the emoji each
    /// became.
    private static let symbols = [
        "globe": "🌐", "folder": "📁", "chevron.left.forwardslash.chevron.right": "⌨️", "doc.text": "📝",
        "envelope.fill": "✉️", "message.fill": "💬", "paintpalette": "🎨", "spark": "✨", "bolt": "⚡️",
        "bag": "🛍️", "airplane": "✈️", "mountain.2.fill": "🏔️", "video": "🎬", "bookmark": "🔖",
    ]

    private static var file: URL { Store.file("spaces.json") }

    /// A symbol's name is all plain letters; anything else is an emoji.
    nonisolated static func isEmoji(_ icon: String) -> Bool { !icon.isEmpty && !icon.allSatisfy(\.isASCII) }

    /// An emoji as a picture, for a menu item, which takes images; a
    /// symbol as a template, inked as the menu's words are.
    static func picture(emoji: String, side: CGFloat) -> NSImage {
        if !isEmoji(emoji), let art = SpaceIconArt.art(emoji)?.copy() as? NSImage {
            art.size = NSSize(width: side * 0.7, height: side * 0.7)
            return art
        }
        if !isEmoji(emoji), let symbol = NSImage(systemSymbolName: emoji, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side * 0.7, weight: .medium)) {
            symbol.isTemplate = true
            return symbol
        }
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let text = emoji as NSString
            let font = NSFont.systemFont(ofSize: side * 0.86)
            let size = text.size(withAttributes: [.font: font])
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: [.font: font])
            return true
        }
    }

    /// Every space in its kept order, the first one made on the spot, on
    /// top, if there is no list yet.
    static func read() -> [Space] {
        glazeOnce()
        // Pending manual deletions can still have rows until finishErasing.
        let pending = (Store.settings.stringArray(forKey: "spaces.erasing-soon") ?? [])
            .compactMap { $0.split(separator: ":").first.flatMap { UUID(uuidString: String($0)) } }
        let excluded = Set(pending).union([Space.pinsID, Space.mailID])
        var saved = SpaceRecovery.read(at: file, excluding: excluded) ?? []
        // Brought in before they could be one: joined now, and what each
        // has so far kept (`healLinked`).
        let joined = link(&saved)
        if !joined.isEmpty {
            write(saved)
            joinedKept(joined)
        }
        routes = routing(saved)
        sharing = Set(saved.filter { !$0.ownSignIns }.map(\.id))
        // Symbols from before, each its emoji, written back once; one
        // picked from the Icon tab (SpaceSymbols) stays.
        let old = { (icon: String) in !isEmoji(icon) && !SpaceSymbols.all.contains { $0.symbol == icon } }
        if saved.contains(where: { old($0.icon) }) {
            for at in saved.indices where old(saved[at].icon) {
                saved[at].icon = symbols[saved[at].icon] ?? "📁"
            }
            write(saved)
        }
        if !saved.isEmpty { return saved }
        return [Space(id: Space.firstID, name: "Personal", icon: "🏠", ownSignIns: false)]
    }

    /// Spaces on when nothing says either way: the settings gone while the
    /// folder stayed, as an uninstaller that sweeps ~/Library/Preferences
    /// leaves it (feedback #320). More spaces kept than the one every Mac
    /// starts with were made with spaces on; left off, every other space
    /// was there and could not be gone to. A choice written down stays.
    nonisolated static func on(settings: UserDefaults, kept file: URL) -> Bool {
        if let chosen = settings.object(forKey: "spaces") as? Bool { return chosen }
        if let data = try? Data(contentsOf: file) {
            if let saved = try? JSONDecoder().decode([Space].self, from: data) { return saved.count > 1 }
            // A damaged list SpaceRecovery repairs: its rows still count.
            if let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] { return rows.count > 1 }
        }
        // None readable: a row of a space other than the first was saved
        // with spaces on (SpaceRecovery brings those spaces back).
        let names = (try? FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)) ?? []
        return names.contains { $0.hasPrefix("session-") && $0.hasSuffix(".json") && UUID(uuidString: String($0.dropFirst(8).dropLast(5))) != nil }
    }

    /// Glass was one switch for every window (Settings › Experimental):
    /// a Mac that had it on keeps it, now in each space's look and the
    /// window's, and the old switch is gone. Once, before either is read.
    static func glazeOnce() {
        guard !glazed else { return }
        glazed = true
        let store = Store.settings
        defer {
            store.removeObject(forKey: GlassExperiment.key)
            store.removeObject(forKey: GlassExperiment.offeredKey)
        }
        guard store.bool(forKey: GlassExperiment.key) else { return }
        store.set(true, forKey: "backdrop.glass")
        // It framed the page even edge to edge; a look wears it on a color.
        if store.string(forKey: "backdrop") == Backdrop.none.rawValue { store.set(Backdrop.color.rawValue, forKey: "backdrop") }
        guard var saved = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode([Space].self, from: $0) }) else { return }
        for at in saved.indices { saved[at].paint?.glass = true }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private static var glazed = false

    static func write(_ spaces: [Space]) {
        guard SpaceRecovery.preserveInvalid(at: file) else { return }
        guard let data = try? JSONEncoder().encode(spaces) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        routes = routing(spaces)
        sharing = Set(spaces.filter { !$0.ownSignIns }.map(\.id))
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Pages counted from the files of spaces not opened since launch
    /// (Browser.pageCount).
    static var pageCounts: [UUID: Int] = [:]

    /// The space new tabs are made in: the one on screen.
    static var current = Space.firstID
    /// The spaces signed in wherever the first one is.
    static var sharing: Set<UUID> = []
    /// Spaces turned off, the window going back to the first one.
    static var leaving = false

    /// The spaces signed in with another's own sign-ins (Space.signInWith).
    private(set) static var routes: [UUID: UUID] = [:]

    /// Whose own sign-ins a space's are: its own id, or the space it shares
    /// them with. The id its store and extensions go by.
    static func signIn(of id: UUID) -> UUID { routes[id] ?? id }

    /// A space made signing in with another: before anything asks its store.
    static func joining(_ id: UUID, with owner: UUID) { routes[id] = owner }

    nonisolated static func routing(_ spaces: [Space]) -> [UUID: UUID] {
        var out: [UUID: UUID] = [:]
        for space in spaces where space.ownSignIns {
            if let with = space.signInWith, with != space.id { out[space.id] = with }
        }
        return out
    }

    /// The spaces of one profile of another browser joined into one sign-in,
    /// the first in the list the others' (row 1752). Says who joined whom:
    /// each had a store of its own until now.
    nonisolated static func link(_ spaces: inout [Space]) -> [(from: UUID, to: UUID)] {
        var owners: [String: UUID] = [:]
        var joined: [(from: UUID, to: UUID)] = []
        for space in spaces where space.ownSignIns {
            if let name = space.signedInAs, let with = space.signInWith, owners[name] == nil { owners[name] = with }
        }
        for index in spaces.indices where spaces[index].ownSignIns && spaces[index].signInWith == nil {
            guard let name = spaces[index].signedInAs else { continue }
            guard let owner = owners[name] else {
                owners[name] = spaces[index].id
                continue
            }
            guard owner != spaces[index].id else { continue }
            spaces[index].signInWith = owner
            joined.append((spaces[index].id, owner))
        }
        return joined
    }

    private static let linkedKey = "spaces.linked.cookies"

    /// What the spaces joined had apart: their extensions now, as nothing
    /// has read their lists yet, their cookies at `healLinked`. The stores
    /// left behind stay on disk: nothing of theirs is erased.
    private static func joinedKept(_ joined: [(from: UUID, to: UUID)]) {
        if #available(macOS 15.4, *) {
            for pair in joined { Extensions.merge(signIn: pair.from, into: pair.to) }
        }
        let waiting = Store.settings.stringArray(forKey: linkedKey) ?? []
        Store.settings.set(waiting + joined.map { "\($0.from.uuidString):\($0.to.uuidString)" }, forKey: linkedKey)
    }

    /// Cookies of a store left behind by a join, into the store its space
    /// signs in with now; one held there already stays.
    static func healLinked() {
        let waiting = Store.settings.stringArray(forKey: linkedKey) ?? []
        guard !waiting.isEmpty else { return }
        Task { @MainActor in
            for entry in waiting {
                let parts = entry.split(separator: ":").compactMap { UUID(uuidString: String($0)) }
                if parts.count == 2 {
                    let found = await WKWebsiteDataStore(forIdentifier: parts[0]).httpCookieStore.allCookies()
                    let target = store(for: parts[1]).httpCookieStore
                    let held = Set(await target.allCookies().map(Browser.cookieKey))
                    for cookie in found where !held.contains(Browser.cookieKey(cookie)) { await target.setCookie(cookie) }
                }
                let left = (Store.settings.stringArray(forKey: linkedKey) ?? []).filter { $0 != entry }
                Store.settings.set(left, forKey: linkedKey)
            }
        }
    }

    /// Each space's store, made once: WebKit shares processes between views
    /// that ask for the same store object.
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    /// The space whose own sign-ins `store` is, among those made so far:
    /// none for the shared sign-ins, which several spaces use.
    static func ownSpace(of store: WKWebsiteDataStore) -> UUID? {
        guard store !== Store.websites else { return nil }
        return stores.first { $0.value === store }?.key
    }
    /// The stores of spaces with their own sign-ins opened in this run.
    static var madeStores: [UUID: WKWebsiteDataStore] { stores }

    static func store(for id: UUID) -> WKWebsiteDataStore {
        if id == Space.mailID || id == Space.pinsID || sharing.contains(id) { return Store.websites }
        let id = signIn(of: id)
        if id == Space.firstID { return Store.websites }
        if let made = stores[id] { return made }
        let made = WKWebsiteDataStore(forIdentifier: id)
        // Before anything asks it for its service workers (Extensions.storeMade).
        if #available(macOS 15.4, *) { Extensions.storeMade(made, signIn: id) }
        LastingSignIns.keep(made)
        stores[id] = made
        SiteNotices.listen(made)
        // An extension's proxy reaches a space made since it was set.
        ExtensionProxy.dress(made)
        return made
    }

    /// The store WebKit knows by this identifier, whichever space now
    /// routes its sign-ins elsewhere: a site's web push goes back to the
    /// store its service worker was registered in (WebPush.swift).
    static func store(identified id: UUID) -> WKWebsiteDataStore {
        if let made = stores[id] { return made }
        let made = WKWebsiteDataStore(forIdentifier: id)
        LastingSignIns.keep(made)
        stores[id] = made
        SiteNotices.listen(made)
        return made
    }

    /// A deleted space's store and everything in it, emptied now and removed
    /// once WebKit lets go of it, at the latest at the next launch.
    static func erase(_ id: UUID) {
        guard id != Space.firstID, id != Space.mailID, id != Space.pinsID else { return }
        ChromiumPersistentProfiles.retireAssociation(id)
        WebPush.shared.drop(store: id)
        CertificateExceptions.forget(profile: id)
        Boosts.shared.forget(signIn: id)
        Userscripts.shared.forget(signIn: id)
        // Sign-in routing may already point this space at the shared
        // store (own → shared). Erase only its former dedicated store;
        // using store(for:) here would clear everybody's shared sign-ins.
        let store = stores[id] ?? WKWebsiteDataStore(forIdentifier: id)
        // Its extensions, their list and storage, with its sign-ins.
        if #available(macOS 15.4, *) { Extensions.forget(signIn: id) }
        let everything = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: everything, modifiedSince: .distantPast) {}
        stores[id] = nil
        let pending = Set(Store.settings.stringArray(forKey: "spaces.erasing") ?? []).union([id.uuidString])
        Store.settings.set(pending.sorted(), forKey: "spaces.erasing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { sweep() }
    }

    /// How long a space deleted by hand can come back (deleteSpace).
    static let undoWindow: TimeInterval = 60

    /// A space deleted by hand, its row and sign-ins kept for ⌘Z: listed,
    /// so a quit or crash before the minute is out still erases them.
    static func eraseSoon(_ id: UUID, own: Bool) {
        let soon = Set(Store.settings.stringArray(forKey: "spaces.erasing-soon") ?? []).union([id.uuidString + (own ? ":own" : "")])
        Store.settings.set(soon.sorted(), forKey: "spaces.erasing-soon")
    }

    /// Brought back, or erased now: off that list.
    static func spare(_ id: UUID) {
        let soon = (Store.settings.stringArray(forKey: "spaces.erasing-soon") ?? []).filter { !$0.hasPrefix(id.uuidString) }
        Store.settings.set(soon, forKey: "spaces.erasing-soon")
    }

    /// At launch: what a space deleted just before the last quit left.
    private static var finished = false
    static func finishErasing() {
        guard !finished else { return }
        finished = true
        ChromiumPersistentProfiles.sweepErased()
        let soon = Store.settings.stringArray(forKey: "spaces.erasing-soon") ?? []
        guard !soon.isEmpty else { return }
        Store.settings.removeObject(forKey: "spaces.erasing-soon")
        for entry in soon {
            let parts = entry.split(separator: ":")
            guard let id = parts.first.flatMap({ UUID(uuidString: String($0)) }) else { continue }
            Session.erase(space: id)
            if parts.count > 1 { erase(id) }
        }
    }

    /// Every store of a deleted space that is still there, tried again.
    static func sweep() {
        for text in Store.settings.stringArray(forKey: "spaces.erasing") ?? [] {
            guard let id = UUID(uuidString: text) else { continue }
            Task { @MainActor in
                do { try await WKWebsiteDataStore.remove(forIdentifier: id) } catch {
                    let left = await WKWebsiteDataStore.allDataStoreIdentifiers
                    guard !left.contains(id) else { return }
                }
                let now = (Store.settings.stringArray(forKey: "spaces.erasing") ?? []).filter { $0 != text }
                Store.settings.set(now, forKey: "spaces.erasing")
            }
        }
    }
}

extension Browser {
    /// Whether this window shows spaces: never a private one, which lists
    /// none of yours and goes to none (register 1015).
    var spacesShown: Bool { prefs.usesSpaces && windowPurpose == .normal }

    /// Whether ⌃1 to ⌃9 and Next and Previous Space go anywhere here: a
    /// window that shows spaces, or, with spaces off, Mail's way in and
    /// out, as the foot shows the one space and Mail beside it with ⌃1 and
    /// ⌃2 on them and two fingers go between them (switchSpace). Keyed on
    /// spacesShown alone, ⌃1 in Mail did nothing with spaces off
    /// (feedback #1657).
    var turnsSpaces: Bool {
        spacesShown || (windowPurpose == .normal
                        && (spaceID == Space.mailID || turnOrder.contains { $0.id == Space.mailID }))
    }

    var space: Space { spaceID == Space.mailID ? .mail : spaces.first { $0.id == spaceID } ?? spaces[0] }

    /// The original shared space while it exists, otherwise the first kept
    /// one. Never return the identifier of a deleted Personal space.
    var homeSpaceID: UUID { spaces.first(where: \.isFirst)?.id ?? spaces[0].id }

    func canDeleteSpace(_ id: UUID) -> Bool {
        spaces.count > 1 && spaces.contains { $0.id == id }
    }

    /// The spaces in the order the foot, two fingers, ⌃1 to ⌃9 and a
    /// switch's direction go through them: yours, with Mail among them in
    /// its place once an account is in (MailSpaceLook.place, first until
    /// moved). Mail is never in the saved list. With spaces off, the one
    /// space there is and Mail beside it, as the envelope goes between
    /// them: the others are only kept for when spaces come back
    /// (leaveSpaces), and two fingers out of Mail went to one of them.
    var turnOrder: [Space] {
        // A private window has no spaces to go to, as Arc's has none: never
        // yours listed there, nor Mail (register 1015).
        guard windowPurpose == .normal else { return [space] }
        guard MailCenter.shared.connected, prefs.usesMail else { return spaces }
        var order = prefs.usesSpaces ? spaces : [spaces.first { $0.id == Space.firstID } ?? spaces[0]]
        order.insert(.mail, at: min(MailSpaceLook.place, order.count))
        return order
    }

    /// Whether two fingers over the column have a space to go to: another
    /// of yours with spaces on, or Mail's, which is gone in and out of with
    /// spaces off too (switchSpace). With spaces off they did nothing in
    /// Mail, nor into it (feedback #158).
    var swipesSpaces: Bool {
        let order = turnOrder
        return order.count > 1 && (prefs.usesSpaces || order.contains { $0.id == Space.mailID })
    }

    /// Every tab of the spaces not on screen, for the sleep timer.
    var parkedTabs: [Tab] { parked.values.flatMap(\.tabs) }

    /// The tab with this id in the row on screen.
    private func inRow(_ id: Tab.ID?) -> Tab? { tabs.first { $0.id == id } }

    /// What stays in the row whatever space is on screen: an agent's own
    /// tabs, and a tab of yours an agent is working in, since the agent
    /// finds its tabs in the row.
    /// Not one you sent to a space while an agent was at work in it
    /// (`stays`, `assistantSpace` for an agent's own): it stays there.
    /// A call doesn't: it stays in its space, live, and comes along in the
    /// floating window instead (feedback #1878, liftCall).
    func travels(_ tab: Tab) -> Bool {
        if tab.bench, tab.assistantSpace != nil { return false }
        return tab.bench || Browser.hosts(tab) && !tab.stays
    }

    /// A tab Move to › Space can send: yours, one an agent is at work in
    /// included, and an agent's own that the column shows. Not a script's
    /// bench tab, which shows nowhere, nor an assistant's kept to the one
    /// space its grant names.
    static func movable(_ tab: Tab) -> Bool {
        guard tab.bench else { return true }
        guard let agent = tab.agent, agent != Agents.script else { return false }
        return Agents.shared.assistant(of: agent).map { $0.allSpaces == true } ?? true
    }

    /// What moveTabs sends: a movable tab, a call's too (row 1149), the
    /// same live tab.
    func sendable(_ tab: Tab) -> Bool {
        Browser.movable(tab)
    }

    /// A tab that went along with you (an agent at work in it) and
    /// no longer does, back in the space it came from rather than left in
    /// the one you are in, its folder and kept place that space's (row
    /// 1149: a Meet tab stuck in another space, in its home's folder).
    /// Not the one on screen: it goes once you look away or switch.
    func sendHome(_ tab: Tab) {
        guard let home = tab.homeSpace, !travels(tab), tab.id != activeID, !onScreen(tab.id) else { return }
        tab.homeSpace = nil
        guard home != spaceID, spaces.contains(where: { $0.id == home }),
              let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if floating == tab.id { land() }
        var row = parked[home] ?? loadRow(home)
        var remaining = tabs
        remaining.remove(at: index)
        pairs.removeAll { $0.first == tab.id || $0.second == tab.id }
        lay(remaining)
        let after = row.tabs.lastIndex { $0.pin != nil || ($0.kept && tab.pin == nil) }.map { $0 + 1 } ?? 0
        if tab.pin != nil || tab.kept { row.tabs.insert(tab, at: min(after, row.tabs.count)) } else { row.tabs.append(tab) }
        parked[home] = row
        writeRow(row.tabs, active: row.active, space: home, pairs: row.pairs, now: true)
        rememberSession()
    }

    /// Every tab here that went along with you and no longer does.
    func sendHomeAll() {
        for tab in tabs where tab.homeSpace != nil && !travels(tab) { sendHome(tab) }
    }

    /// A tab of yours with an agent at work in it now. Not one whose guest
    /// has gone: an agent attached through `yab mcp` never says its turn
    /// is over, and a killed one never detaches, so `guest` stays after it
    /// rests (AgentFeed.rest) or ends. Such a tab is an ordinary one again,
    /// in its own space, with Move to › Space (register 1105, x.com's pin).
    static func hosts(_ tab: Tab) -> Bool {
        guard let guest = tab.guest else { return false }
        return Agents.shared.session(guest)?.working ?? true
    }

    /// A row with tabs of the space's own that stay in it: kept tabs and
    /// its own pins, not the shared pins every space shows, nor an agent's
    /// that go along.
    static func holdsOwn(_ row: [Tab]) -> Bool {
        row.contains { ($0.kept || $0.pin != nil) && $0.everywhere == nil && !$0.bench && $0.homeSpace == nil && (!hosts($0) || $0.stays) }
    }

    /// ⌃1 to ⌃9, the menu, a swipe.
    /// `washed`: the fingers already have the new color over the window
    /// (SpacePull), and hand it over themselves.
    func switchSpace(to id: UUID, washed: Bool = false) {
        guard windowPurpose == .normal else { return }
        // Mail's space is gone in and out of with spaces off too (MailSpace).
        let mail = id == Space.mailID || spaceID == Space.mailID
        // A Blank Window stays in the space it signs in as, unless that
        // space is gone (Arc's Spaces menu is off there).
        guard !blank || !spaces.contains(where: { $0.id == spaceID }) else { return }
        guard prefs.usesSpaces || mail, id != spaceID, mail || spaces.contains(where: { $0.id == id }) else { return }
        ColumnSpaceCarry.of(self)?.willPage()
        defer { ColumnSpaceCarry.of(self)?.switched() }
        if !washed { SpacePull.shared.interrupt(in: self) }
        SwitchMeter.start()
        defer { SwitchMeter.mark("done") }
        // A pair still coming together or apart finishes first, in this space.
        settleNow()
        // Across the top, the strip as it is now, pictured for its turn
        // (StripView); and how far two fingers had taken it.
        let strip = prefs.sidebar || id == Space.mailID || spaceID == Space.mailID ? nil : StripView.of(self)
        let stripBefore = strip?.prepare()
        let spaceBefore = space
        let turnStart = SpaceShown.shared.handoff
        let order = turnOrder.map(\.id)
        let forward = (order.firstIndex(of: id) ?? 0) > (order.firstIndex(of: spaceID) ?? 0)
        // The page in front there on screen now, from its last frame,
        // before anything of the switch is written for SwiftUI (PageStills).
        let visit = carryHome.map { $0 != id && id != Space.mailID } ?? false
        if !visit, let row = parked[id], let front = row.tabs.first(where: { $0.id == row.active }),
           !row.pairs.contains(where: { $0.contains(front.id) }) {
            showEarly(front)
        }
        // The strip's turn sets off now, from its picture, with the page put
        // up first, before the switch writes anything: put on screen after
        // the writes, its flush laid the whole window out first, 40 ms with
        // nothing moving (StripView).
        if let strip, let stripBefore, let target = spaces.first(where: { $0.id == id }) {
            strip.turn(from: stripBefore, old: spaceBefore, new: target, way: forward ? 1 : -1, start: turnStart)
            SwitchMeter.mark("strip")
        }
        let intoMail = id == Space.mailID, outOfMail = spaceID == Space.mailID
        guard !intoMail || prefs.usesMail else { return }
        // The column's spaces slide as one row, the one on screen pictured
        // before anything changes (SpacePager).
        let paging = SpacePager.shared.turn(self, to: id)
        SwitchMeter.mark("turn")
        // The row of spaces and the window's color set off now, sent to the
        // render server before anything else of the switch is done: the
        // pages already show both spaces, and the column under them is
        // masked. Left to the end of the switch, they waited for the window
        // to be laid out for the new space, every one of its rows made, the
        // page and the strip: 100 to 250 ms with nothing moving after the
        // key, more with more tabs (feedback, 2026-10-09). The page and the
        // rows under the mask come in that time, as the row slides.
        let washedEarly = paging && !washed ? setOff(to: id) : false
        if intoMail { mailComing() }
        cancelTabEdit()
        hidePeek()
        // The page you were on, to stand under the field if the space you
        // go to has nothing in it (`Under`): this row's, or the one already
        // standing there from a space before, in the space it lives in.
        let page = active.flatMap { $0.isBlank || $0.shy ? nil : $0 } ?? underTab
        var pageSpace = spaceID
        if case .space(_, let from) = under { pageSpace = from }
        // A call stays in its space, live, its tab parked there: one out in
        // its window stays out, one on screen as you go is taken out into
        // it once you are there (feedback #1878). A video out stays out
        // too, its tab parked in the space it is in, as Arc's does; one
        // playing in front comes out as for a tab left.
        if floating == nil { leavingSpace() }
        let callHere = active?.onCall == true ? active : nil
        // Those that went along and no longer do go back to their own.
        sendHomeAll()
        // The shared pins go along between two spaces that show them, one
        // live tab each, and are put aside going into one that doesn't
        // (SharedPins.swift).
        settleShared(tabs, in: spaceID)
        let fromShowing = showsShared(spaceID), toShowing = showsShared(id)
        let pinOrder = sharedPins?.map(\.id)
        // Everything the switch writes, in one transaction (`quietly`).
        quietly {
            spaceStep = forward ? 1 : -1
            pinsStayed = fromShowing && toShowing
            let along = { (tab: Tab) in self.travels(tab) || tab.everywhere != nil && fromShowing && toShowing }
            let staying = tabs.filter(along)
            // Each knows the space it came from, its folder's and kept
            // place's (`home`), and is back at home there.
            for tab in staying where !tab.bench && tab.everywhere == nil {
                if tab.homeSpace == nil { tab.homeSpace = spaceID } else if tab.homeSpace == id { tab.homeSpace = nil }
            }
            let leaving = tabs.filter { !along($0) && $0.everywhere == nil }
            let aside = tabs.filter { !along($0) && $0.everywhere != nil }
            // Pairs go with the row their two tabs are in.
            let gone = Set(leaving.map(\.id))
            let leavingPairs = pairs.filter { gone.contains($0.first) && gone.contains($0.second) }
            let visited = visitFronts.removeValue(forKey: spaceID)
            writeRow(leaving, active: visited ?? activeID, space: spaceID, pairs: leavingPairs)
            // Parked as it is: music keeps playing in the space you left, as
            // it does in a tab you left. ⌘⇧M, or its speaker, stops it. Left
            // on a shared pin, it comes back on it.
            let onShared = fromShowing && tabs.contains { $0.id == activeID && $0.everywhere != nil }
            // With none in front, or one that goes along (an agent's, a
            // call), it is left with none, not on its first tab.
            let left = visited ?? (leaving.contains { $0.id == activeID } || onShared ? activeID : nil)
            parked[spaceID] = Parked(tabs: leaving, active: left, pairs: leavingPairs)
            // Pairs pinned as one among the shared pins go with them, along
            // or aside (PinPairs.swift).
            let both = { (row: [Tab], pair: Pair) in row.contains { $0.id == pair.first } && row.contains { $0.id == pair.second } }
            let alongPairs = pairs.filter { both(staying.filter { $0.everywhere != nil }, $0) }
            let asidePairs = pairs.filter { both(aside, $0) }
            if !toShowing, fromShowing || !aside.isEmpty { parkShared(aside, order: pinOrder, leaving: fromShowing ? spaceID : nil, pairs: asidePairs) }
            pairs = []

            keepPaint()
            rowTurning = true
            spaceID = id
            if windowID == nil { Spaces.current = id }
            // Mail is left for the space you were in at the next launch.
            let currentKey = windowID.map { "window.\($0.uuidString).space" } ?? "space.current"
            if id != Space.mailID { Store.settings.set(id.uuidString, forKey: currentKey) }
            // The window's color and grain in the same beat as the rows and the
            // wash (P9): the space is the room. Worn at once, under the old one,
            // which clears in the render server (SpaceWash).
            if let paint = space.paint {
                let old = SpaceWash.grounded(in: self)
                let wash = spaceWash
                wash.turning = true
                quietly { paint.wear(prefs) }
                // On the row's own spring when the column slides.
                if !washed, !washedEarly, !SpaceTurn.still, let old {
                    // Across the top, on the turn's spring, with the capsule (StripTurn).
                    if !prefs.sidebar, !paging {
                        spaceWash.clearOnStrip(old, from: washFrom, base: SpaceWash.grounded(in: self))
                    } else {
                        spaceWash.clear(old, from: 1, spring: paging, base: SpaceWash.grounded(in: self))
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { wash.turning = false }
            }
            if id == Space.mailID { MailSpaceLook.worn[ObjectIdentifier(self)] = SpacePaint(prefs) }
            // Mail's space comes back with its tabs, asleep, and mail's page
            // in front, made afresh (mailCame).
            var back = parked.removeValue(forKey: id) ?? (id == Space.mailID ? Parked(tabs: loadRow(id).tabs, active: nil) : loadRow(id))
            // With them, any a call or an agent took into a space of its own
            // and has let go of since: they stood there, and join the rest.
            if toShowing { back = joinShared(back, along: staying.filter { $0.everywhere != nil } + aside, fromShowing: fromShowing, alongPairs: alongPairs + asidePairs) }
            if visit {
                if let front = back.active { visitFronts[id] = front }
                back.active = nil
            }
            present(back, staying: toShowing ? staying.filter { $0.everywhere == nil } : staying)
            // The new row's folders and line worked out now, in this
            // transaction: left to Folders' own watch a turn later, the
            // switch's pass drew the row without them, the kept folder's
            // tucked rows made and shown, and a second pass made the
            // folders and took those rows out again.
            if folderBook.browser === self { folderBook.refresh() }
            rowTurning = false
            // Nothing in it: the field, over the page you were on. Escape
            // takes you back to it (`backOut`). A space of kept tabs or pins
            // of its own, none in front (each put down with ⌘W), is not
            // empty: the field on its own ground, as Arc's empty window,
            // never the last space's page behind it (feedback #370).
            if active == nil {
                if id != Space.mailID, visit || !Browser.holdsOwn(tabs), let page { under = .space(page, from: pageSpace) } else { settleUnder() }
            }
            typed = ""
            fieldPutAway = false
            // In the same transaction: asked after it, the field's request
            // was a change in a transaction of its own, and SwiftUI laid the
            // whole window out for the new space there and then to keep the
            // two apart, then again for the frame, 40 ms of a switch with
            // the tabs across the top.
            askFocus()
            // Drawn from the next frame on: the capsule, the strip's lead and
            // the rows' arrival start once this frame's work is done. The
            // strip's turn is begun here (StripTurns), in this transaction:
            // begun after it, its own write had SwiftUI lay the whole window
            // out for the new space there and then, 23 ms before the
            // switch's frame, and again for the frame.
            SpaceShown.shared.follow(id)
        }
        SwitchMeter.mark("written")
        if intoMail { mailCame() } else if outOfMail { mailLeft() }
        SwitchMeter.mark(intoMail ? "mail came" : outOfMail ? "mail left" : "arrived")
        // Back in the space whose tab in front has its video or its call
        // out: home.
        if let floating, floating == activeID { land(home: true) }
        if let callHere, activeID != callHere.id, prefs.floatsOnLeave { liftCall(callHere) }
        // The row of spaces lands on this one, in the render server, while
        // the main thread lays it out under the pages.
        if paging { SpacePager.shared.land() }
    }

    /// The row of spaces landing on `id`, and the window's color crossing
    /// to that space's on the same spring, committed to the render server
    /// at once (switchSpace). True when the color was crossed here, for the
    /// switch not to cross it again. The window wears the new color under
    /// the old one now, as SwiftUI's pass for the switch would have it, so
    /// the two are crossed from the first frame of the slide.
    private func setOff(to id: UUID) -> Bool {
        var crossed = false
        if !SpaceTurn.still, let paint = (id == Space.mailID ? Space.mail : spaces.first(where: { $0.id == id }))?.paint,
           let old = SpaceWash.grounded(in: self), let new = SpaceWash.grounded(paint, in: self) {
            spaceWash.backdrop?.wear(new)
            spaceWash.clear(old, from: 1, spring: true, base: new)
            crossed = true
        }
        SpacePager.shared.land()
        CATransaction.flush()
        SwitchMeter.mark("set off")
        return crossed
    }

    /// The window's color and grain as they are, kept with the space on
    /// screen: whatever Settings changed while it was up is its own.
    func keepPaint() {
        if inMail {
            // Mail follows the space you came from until its look is
            // changed in it: then that look is Mail's (MailSpaceLook.worn).
            let now = SpacePaint(prefs)
            if now != MailSpaceLook.worn[ObjectIdentifier(self)], now != Space.mail.paint { MailSpaceLook.keep(now) }
            return
        }
        guard let at = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        let now = SpacePaint(prefs)
        guard spaces[at].paint != now else { return }
        spaces[at].paint = now
        Spaces.write(spaces)
    }

    /// ⌃1 to ⌃9: the spaces as the foot shows them, Mail in its place.
    func switchSpace(index: Int) {
        let order = turnOrder
        guard order.indices.contains(index) else { return }
        switchSpace(to: order[index].id)
    }

    /// The next space along, or the one before, round the ends, Mail's
    /// among them (turnOrder).
    func stepSpace(_ by: Int) {
        let order = turnOrder
        guard turnsSpaces, let here = order.firstIndex(where: { $0.id == spaceID }),
              let there = StripTurn.step(from: here, count: order.count, by: by) else { return }
        switchSpace(to: order[there].id)
    }

    /// The icon a new space gets: the first no space wears yet.
    var freeIcon: String {
        let used = Set(spaces.map(\.icon))
        return Spaces.icons.first { !used.contains($0) } ?? "📁"
    }

    /// A new space, empty, and on screen: signed in where the others are,
    /// or starting afresh with cookies of its own; in the color and grain
    /// given, or the window's as it is. The tab taken along leaves the
    /// space it was in for the new one: the same tab when the sign-ins are
    /// shared, its page opened afresh in the new space's own otherwise.
    /// `show`: false from Settings, where the space is made and the
    /// window stays in the one it is in. `washed`: the window already wears
    /// its look (New Space's preview), so the old one isn't crossed out.
    @discardableResult
    func addSpace(named name: String, icon: String? = nil, ownSignIns: Bool, paint: SpacePaint? = nil, taking: [Tab] = [], show: Bool = true, washed: Bool = false) -> UUID {
        let made = Space(id: UUID(), name: name, icon: icon ?? freeIcon, ownSignIns: ownSignIns, paint: paint ?? SpacePaint(prefs), iconChoice: icon,
                         iconChoiceID: icon.map { _ in UUID().uuidString })
        let from = spaceID
        spaces.append(made)
        if !ownSignIns { Spaces.sharing.insert(made.id) }
        Spaces.write(spaces)
        guard show else { return made.id }
        // The shared pins are every space's already: none is taken along.
        let taking = taking.filter { $0.everywhere == nil }
        // One an agent is at work in, and an agent's own, stay in the new
        // space from here (moveTabs): marked before the switch, they are
        // left in this row rather than going along, and come over as the
        // same tabs, the agent's to go on in, never opened afresh. A call
        // comes over as the same tab too, still live, never opened afresh.
        let marked = taking.filter { $0.bench || Browser.hosts($0) }
        for tab in marked {
            tab.homeSpace = nil
            if tab.bench { tab.assistantSpace = made.id } else { tab.stays = true }
        }
        let held = marked + taking.filter { $0.onCall && !$0.bench && !Browser.hosts($0) }
        switchSpace(to: made.id, washed: washed)
        guard !taking.isEmpty, spaceID == made.id else { return made.id }
        let reopened = ownSignIns ? taking.filter { tab in !held.contains { $0 === tab } } : []
        for (index, tab) in reopened.enumerated() {
            guard let url = tab.pending ?? tab.address else { continue }
            if index == 0, let blank = active, blank.isBlank { blank.go(to: url) } else { open(url, foreground: index == 0) }
            closeParked(tab, in: from)
        }
        let carried = ownSignIns ? held : taking
        if !carried.isEmpty, var row = parked[from] {
            let ids = Set(carried.map(\.id))
            let moving = row.tabs.filter { ids.contains($0.id) }
            guard !moving.isEmpty else { return made.id }
            row.tabs.removeAll { ids.contains($0.id) }
            if let active = row.active, ids.contains(active) { row.active = nil }
            row.pairs.removeAll { ids.contains($0.first) || ids.contains($0.second) }
            parked[from] = row
            writeRow(row.tabs, active: row.active, space: from, pairs: row.pairs, now: true)
            moving.forEach { tab in
                tab.pin = nil
                tab.kept = false
                tab.nest = nil
            }
            // The blank tab the empty space was given makes way for them,
            // after the shared pins.
            let blanks = tabs.filter { $0.isBlank && !$0.bench }
            let rest = tabs.filter { tab in !blanks.contains { $0 === tab } }
            showRow(rest.filter { $0.everywhere != nil } + moving + rest.filter { $0.everywhere == nil }, active: reopened.isEmpty ? moving[0].id : activeID ?? moving[0].id)
            blanks.forEach { $0.close() }
            if moving[0].asleep { moving[0].wake() }
            rememberSession()
        }
        return made.id
    }

    /// A tab of a parked row, closed there and written out of it.
    func closeParked(_ tab: Tab, in space: UUID) {
        guard var row = parked[space], let at = row.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        row.tabs.remove(at: at)
        if row.active == tab.id { row.active = nil }
        row.pairs.removeAll { $0.first == tab.id || $0.second == tab.id }
        parked[space] = row
        writeRow(row.tabs, active: row.active, space: space, pairs: row.pairs, now: true)
        tab.close()
        if underTab === tab { settleUnder() }
        // The extensions are told the window's tabs, its other spaces' too.
        if #available(macOS 15.4, *) { Extensions.all.forEach { $0.rowChanged() } }
    }

    func renameSpace(_ id: UUID, to name: String) {
        guard let at = spaces.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        let was = spaces[at].name
        spaces[at].name = name
        Spaces.write(spaces)
        if was != name, Browser.handMade { did { [weak self] in self?.renameSpace(id, to: was) } }
    }

    func setSpaceIcon(_ id: UUID, to icon: String) {
        if id == Space.mailID {
            MailSpaceLook.setIcon(icon)
            return
        }
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].chooseIcon(icon)
        Spaces.write(spaces)
    }

    /// The engine the field searches with in a space: an Engine's raw
    /// value, nil for Settings › Search's; `custom`, Other…'s results page.
    func setSpaceSearch(_ id: UUID, to search: String?, custom: String? = nil) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        let search = search.flatMap(Engine.init(rawValue:))?.rawValue
        let page = custom?.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = search == Engine.custom.rawValue && page?.isEmpty == false ? custom : nil
        guard spaces[at].search != search || spaces[at].searchCustom != custom else { return }
        spaces[at].search = search
        spaces[at].searchCustom = custom
        Spaces.write(spaces)
    }

    /// A space's color and grain: worn now if it is the one on screen,
    /// kept for when it is next if not.
    func setSpacePaint(_ id: UUID, to paint: SpacePaint) {
        if id == Space.mailID {
            if inMail { paint.wear(prefs); MailSpaceLook.worn[ObjectIdentifier(self)] = paint }
            MailSpaceLook.keep(paint)
            return
        }
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        if id == spaceID { paint.wear(prefs) }
        guard spaces[at].paint != paint else { return }
        spaces[at].paint = paint
        Spaces.write(spaces)
    }

    /// Shared sign-ins or its own, after it was made. Its tabs are opened
    /// again in the other store, asleep but the one in front, as a row
    /// comes back from its file. A previous profile stays on disk.
    func setSpaceSignIns(_ id: UUID, own: Bool) {
        setSpaceProfile(id, with: own ? nil : Space.firstID)
    }

    /// Membership is a logical store identity, never a chain of Space links.
    func setSpaceProfile(_ id: UUID, with other: UUID?) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        let target = other.flatMap { target in spaces.first { $0.id == target } }
        guard other == nil || target != nil else { return }
        let store: UUID
        if let target {
            store = target.profileID
        } else {
            // Detaching the original owner must not move the other members.
            store = Space.ownProfile(for: spaces[at], among: spaces)
        }
        applySpaceProfile(id, store: store)
    }

    /// Other windows and remote metadata use the same row reconstruction.
    func reloadSpaceProfile(_ id: UUID, previouslyShared: Bool) {
        guard let space = spaces.first(where: { $0.id == id }) else { return }
        applySpaceProfile(id, store: space.profileID, reload: true, previouslyShared: previouslyShared)
    }

    private func applySpaceProfile(_ id: UUID, store: UUID, reload: Bool = false, previouslyShared: Bool? = nil) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        let oldStore = spaces[at].profileID
        guard reload || store != oldStore else { return }
        let own = store != Space.firstID
        // Written out in the store they are in now, and closed there. The
        // shared pins are no space's own: they stay, or are put aside once
        // the space has sign-ins of its own (SharedPins.swift).
        if id == spaceID { settleShared(tabs, in: id) }
        let wasShowing = previouslyShared.map { $0 && prefs.pinsEverySpace } ?? showsShared(id)
        let pinOrder = sharedPins?.map(\.id)
        var row: Parked?
        if id == spaceID {
            settleNow()
            cancelTabEdit()
            hidePeek()
            // A call out from another space stays out; anything of this
            // row's goes home before the row is made again.
            if let floating, !(floater.kind == .call && inRow(floating) == nil) { land() }
            let leaving = tabs.filter { !travels($0) && $0.everywhere == nil }
            let gone = Set(leaving.map(\.id))
            writeRow(leaving, active: activeID, space: id, pairs: pairs.filter { gone.contains($0.first) && gone.contains($0.second) }, now: true)
            row = Parked(tabs: leaving, active: activeID)
        } else if let kept = parked.removeValue(forKey: id) {
            writeRow(kept.tabs, active: kept.active, space: id, pairs: kept.pairs, now: true)
            kept.tabs.forEach { $0.close() }
        }
        spaces[at].ownSignIns = own
        // Given a store of its own or the shared one, it is out of the
        // profile it came in as; another space may go on using its store.
        spaces[at].signInWith = own && store != id ? store : nil
        spaces[at].signedInAs = nil
        if own { Spaces.sharing.remove(id) } else { Spaces.sharing.insert(id) }
        if !reload { Spaces.write(spaces) }
        // Membership changes must not erase the former profile's signed-in
        // session, which another Space may still need.
        // Its buttons are its sign-in's extensions now (ExtensionSignIns).
        if #available(macOS 15.4, *) { DispatchQueue.main.async { ExtensionsHere.shared.refresh() } }
        // On screen: the same row, made again with the new sign-ins, the
        // shared pins at its head if it shows them now, and its own pins,
        // signing in where the others do now, among them.
        guard let row else { return }
        let shared = tabs.filter { $0.everywhere != nil && !travels($0) }
        let sharedPairs = pinPairs(among: shared)
        // Release the old instances before restoring their session identities.
        // Tab.returning correctly rejects an id still held by a live tab;
        // loading first gave the same pins new ids on a profile change.
        row.tabs.forEach { $0.close() }
        var back = loadRow(id)
        if showsShared(id) {
            back = joinShared(back, along: shared, fromShowing: wasShowing, alongPairs: sharedPairs)
        } else if wasShowing {
            parkShared(shared, order: pinOrder, leaving: nil, pairs: sharedPairs)
        }
        present(back, staying: tabs.filter(travels))
        rememberSession()
    }

    /// A space's row on screen: its tabs and what stays whatever the space,
    /// its pairs side by side again, its page in front awake, and its other
    /// half if it is one.
    private func present(_ back: Parked, staying: [Tab]) {
        // The tab it was left on, if it is still there. Left with none in
        // front, or on one gone since, in another window too: none, the
        // field over the page, as Arc comes back to such a space, never its
        // first pin or folder tab woken for it: every swipe through the
        // spaces after a launch opened an old folder's page (alpha feedback,
        // 2026-10-18). A shared pin only when it was left on one
        // (SharedPins.swift). Mail's page is put in front by mailCame.
        let row = back.tabs + staying
        let front = row.contains { $0.id == back.active } ? back.active
            : spaceID == Space.mailID ? row.first { !$0.bench && $0.everywhere == nil }?.id : nil
        showRow(row, active: front)
        pairs = back.pairs
        if !pairs.isEmpty { keepPairs() }
        restage()
        if let active, active.asleep { active.wake() }
        if let active { wakePartner(of: active) }
        editing = active?.isBlank == true
        if active == nil, !spaceVisiting { askNew() }
    }

    /// Of these stores, those no space signs in with now.
    private func unusedStores(_ ids: [UUID]) -> [UUID] {
        ids.filter { store in !spaces.contains { $0.ownSignIns && Spaces.signIn(of: $0.id) == store } }
    }

    private func eraseUnused(_ ids: [UUID]) { unusedStores(ids).forEach(Spaces.erase) }

    /// Dragged to another place in the tray's list, the first space too.
    func moveSpace(_ id: UUID, to index: Int) {
        guard let from = spaces.firstIndex(where: { $0.id == id }),
              index != from, spaces.indices.contains(index) else { return }
        let space = spaces.remove(at: from)
        spaces.insert(space, at: index)
        Spaces.write(spaces)
    }

    /// Dragged along the foot to another place among them all, Mail's
    /// included (turnOrder): any of them goes anywhere, as in Arc. ⌃1 to
    /// ⌃9 follow.
    func moveInOrder(_ id: UUID, to index: Int) {
        let order = turnOrder
        guard let from = order.firstIndex(where: { $0.id == id }), index != from, order.indices.contains(index) else { return }
        var moved = order
        moved.insert(moved.remove(at: from), at: index)
        // Among your own, the place it takes past the others of yours.
        let mine = moved.filter { $0.id != Space.mailID }
        if id != Space.mailID {
            guard let to = mine.firstIndex(where: { $0.id == id }) else { return }
            if spaces.firstIndex(where: { $0.id == id }) != to { moveSpace(id, to: to) }
        }
        // Mail where the row now has it, whichever of them moved.
        if let mail = moved.firstIndex(where: { $0.id == Space.mailID }), mail != order.firstIndex(where: { $0.id == Space.mailID }) {
            MailSpaceLook.place = mail
            MailSpaceLook.changed()
        }
    }

    /// Another place among them; ⌃1 to ⌃9 follow the order.
    func moveSpace(_ id: UUID, by step: Int) {
        guard let from = spaces.firstIndex(where: { $0.id == id }), spaces.indices.contains(from + step) else { return }
        spaces.swapAt(from, from + step)
        Spaces.write(spaces)
    }

    /// A space, its tabs, and, if it had its own, its cookies and sign-ins,
    /// gone. At least one space stays; the original shared store is never
    /// erased, since other spaces, Mail and extensions may still use it.
    /// `undoable`, deleted by hand: for a minute ⌘Z brings it back whole,
    /// its tabs, routes and sign-ins, which are erased only after it.
    func deleteSpace(_ id: UUID, on corner: Toaster? = nil, undoable: Bool = false) {
        guard canDeleteSpace(id), let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        // Another window may be showing this Space and its live pages.
        let otherWindows = BrowserWindows.shared.browsers.filter { $0 !== self }
        guard !otherWindows.contains(where: { $0.spaceID == id }) else {
            announce("Switch the other window away from this Space first", mark: "macwindow.on.rectangle", on: corner)
            return
        }
        // The one above on screen in its place (below, for the top one), in
        // the same beat.
        if spaceID == id {
            let enabled = prefs.usesSpaces
            prefs.usesSpaces = true
            switchSpace(to: spaces[at > 0 ? at - 1 : 1].id)
            prefs.usesSpaces = enabled
        }
        // Its pages kept for ⌘⇧T, whether or not its row was ever opened.
        let before = steps.count
        let batch = rememberClosed(pages(in: id))
        for tab in parked.removeValue(forKey: id)?.tabs ?? [] { tab.close() }
        for browser in otherWindows {
            for tab in browser.parked.removeValue(forKey: id)?.tabs ?? [] { tab.close() }
        }
        let gone = spaces[at]
        let shared = Spaces.sharing.contains(id)
        let routes = LinkRoutes.shared.routes.filter { $0.space == id }
        let kept = LinkRoutes.shared.kept.filter { $0.space == id }
        spaces.remove(at: at)
        Spaces.sharing.remove(id)
        Spaces.write(spaces)
        // Links its routes sent here go to the space on screen again.
        LinkRoutes.shared.forget(space: id)
        // Its store only when no space left signs in with it; the store it
        // used of a space deleted before, when it was the last on it.
        let stores = !gone.ownSignIns ? [] : unusedStores([id, gone.signInWith].compactMap { $0 })
        let erase = {
            Session.erase(space: id)
            stores.forEach(Spaces.erase)
        }
        guard undoable else { return erase() }
        // Its pages come back with it, not into the space on screen.
        if steps.count > before, case .closed? = steps.last { steps.removeLast() }
        // Erased after the minute, or at the next launch if the app is gone by then.
        Spaces.eraseSoon(id, own: stores.contains(id))
        for store in stores where store != id { Spaces.eraseSoon(store, own: true) }
        let wait = Undone()
        did(until: Date().addingTimeInterval(Spaces.undoWindow)) { [weak self] in
            guard let self, !wait.done else { return }
            wait.done = true
            Spaces.spare(id)
            for store in stores where store != id { Spaces.spare(store) }
            if spaces.contains(where: { $0.id == id }) { return }
            spaces.insert(gone, at: min(at, spaces.count))
            if shared { Spaces.sharing.insert(id) }
            Spaces.write(spaces)
            LinkRoutes.shared.bringBack(routes, kept: kept)
            if let batch { forgetGhosts(batch: batch) }
            switchSpace(to: id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Spaces.undoWindow) {
            guard !wait.done else { return }
            wait.done = true
            Spaces.spare(id)
            erase()
        }
    }

    // MARK: a tab to another space

    /// ⌃⇧1 to ⌃⇧9, the tab's menu, a tab let go over a space in the tray:
    /// the tabs picked, the other half of a pair with its half, into
    /// another space's row, after its pins if pinned and at its end if
    /// not. The window stays where it is: the tabs were sent, not followed.
    /// The same tabs, playing and all, when the two spaces keep one set of
    /// sign-ins; their pages opened afresh in the other's store when not.
    /// A tab an agent is at work in, and an agent's own, go too, the same
    /// tabs whatever the sign-ins, and stay there from then on (`stays`,
    /// `assistantSpace`); a script's bench tab never. A pin arrives a pin,
    /// with its address, name and icon, as Arc's pinned tabs do; a shared
    /// pin stays where it is for a space that shows the shared pins, which
    /// has it already (SharedPins.swift), and goes to a space with
    /// sign-ins of its own as that space's own pin. `say`: the corner
    /// says where they went, with Undo, for a move made where nothing on
    /// screen shows it (the menu, the keys); a drop onto the tray has.
    /// `step`: its own step for ⌘Z; off when a folder's move makes one of
    /// its own around it (`moveFolder`).
    @discardableResult
    /// `top`: today's tabs at the top of the other's today's, as a folder
    /// of today's lands in Arc.
    func moveTabs(_ picked: [Tab], to target: UUID, say: Bool = true, step own: Bool = true, top: Bool = false) -> SpaceMove? {
        // Out of a Blank Window into the space, in a window of yours.
        if blank { moveOutOfBlank(picked, to: target, say: say); return nil }
        guard prefs.usesSpaces, target != spaceID, let to = spaces.first(where: { $0.id == target }) else { return nil }
        settleNow()
        cancelTabEdit()
        var ids = Set(picked.map(\.id))
        for tab in picked { if let other = partner(of: tab) { ids.insert(other.id) } }
        // Nor the shared pins, for a space that has them already.
        let moving = tabs.filter { ids.contains($0.id) && sendable($0) && !pinnedAlready($0, in: target) }
        guard !moving.isEmpty else {
            // Only shared pins picked: nothing moves, and the corner says
            // where they are, rather than nothing at all.
            if say, tabs.contains(where: { ids.contains($0.id) && pinnedAlready($0, in: target) }) {
                toaster.pop("Already pinned in \(to.name)", mark: to.icon, undo: { [weak self] in
                    self?.switchSpace(to: target)
                }, act: "Go There")
            }
            return nil
        }
        ids = Set(moving.map(\.id))
        if let floating, ids.contains(floating) { land() }
        moving.forEach { dropPeek(of: $0) }
        let from = spaceID
        let places = moving.map { tab in tabs.firstIndex { $0.id == tab.id } ?? 0 }
        let wasActive = activeID
        let going = pairs.filter { ids.contains($0.first) && ids.contains($0.second) }
        // A folder is in one space only: one all of whose tabs go goes with
        // them, out of a folder that stays; a tab whose folder stays
        // leaves it, as in Arc, and lands loose.
        var cuts: [(nest: Nest, parent: Nest)] = [], unnested: [Tab.ID: Nest] = [:], gone: [Nest] = []
        func whole(_ nest: Nest) -> Bool { !tabs.contains { $0.nest?.within(nest) == true && !ids.contains($0.id) } }
        for tab in moving {
            guard let nest = tab.nest else { continue }
            guard let top = nest.chain.first(where: whole) else {
                unnested[tab.id] = nest
                tab.nest = nil
                continue
            }
            if let parent = top.parent {
                cuts.append((top, parent))
                top.parent = nil
            }
            if !gone.contains(where: { $0 === top }) { gone.append(top) }
        }
        let empties = folderBook.empties.filter { empty in gone.contains { empty.within($0) } }
        folderBook.send(empties, from: from, to: target)
        // One an agent is at work in stays in the space it was sent to
        // rather than going along into every space; its own takes that
        // space for its home (AssistantTabSpace). Undo gives back both.
        var homes: [Tab.ID: UUID?] = [:]
        for tab in moving where tab.bench || Browser.hosts(tab) {
            homes[tab.id] = tab.bench ? tab.assistantSpace : nil
            if tab.bench { tab.assistantSpace = target } else { tab.stays = true }
        }
        // Sent, a tab's space is where it went.
        for tab in moving { tab.homeSpace = nil }
        let arrived = send(moving, pairs: going, from: from, to: target, top: top)

        // Out of this row: the neighbor where the first of them stood is
        // in front, as after ⌘W, or the field if nothing is left.
        _ = unpick()
        pairs.removeAll { ids.contains($0.first) || ids.contains($0.second) }
        let left = tabs.filter { !ids.contains($0.id) }
        lay(left)
        if let wasActive, ids.contains(wasActive) {
            let own = left.filter { !$0.bench }
            if inMail, let mail = mailPageTab {
                // Out of mail's space: mail, as it was left (MailTabRows).
                select(mail)
            } else if own.isEmpty {
                // Nothing left here: the field, on the window's own ground.
                activeID = nil
                askNew()
            } else {
                let first = places.min() ?? 0
                select(left[min(first, left.count - 1)])
            }
        }
        // The row it left, written now as the row it went to was (send):
        // every other window has both at once, as a close is told at once.
        // Left to the session's 1.2 s, the other windows had the tab in
        // both spaces meanwhile (feedback #1808).
        writeSession(now: true)
        let move = SpaceMove(from: from, to: target, wasActive: wasActive,
                             tabs: zip(moving, zip(arrived, places)).map { SpaceMove.Moved(original: $0.id, now: $1.0, at: $1.1) },
                             cuts: cuts, unnested: unnested, empties: empties, homes: homes)
        // By hand, a step for ⌘Z, the menu's and a drop on the tray's alike.
        var step: UUID?
        if own, Browser.handMade {
            step = did { [weak self] in
                guard let self else { return }
                if spaceID != move.from { switchSpace(to: move.from) }
                undoMove(move)
            }
        }
        if say {
            let words = moving.count == 1 ? "Moved to \(to.name)" : "Moved \(moving.count) tabs to \(to.name)"
            toaster.pop(words, mark: to.icon, undo: { [weak self] in
                if let step { self?.undo(step: step) } else { self?.undoMove(move) }
            }, feedback: .success)
        }
        return move
    }

    /// A shared pin, for a space that shows the shared pins: it is in that
    /// space's pins already, the same live tab, and has nowhere to go.
    func pinnedAlready(_ tab: Tab, in target: UUID) -> Bool {
        tab.everywhere != nil && showsShared(target)
    }

    // MARK: a folder to another space

    /// Move to Space on a folder of yours, as Arc's Move to › a space, or
    /// the folder let go over a space in the foot or the tray: every tab
    /// under it and under its folders, and the empty ones in it, into
    /// `target`'s row, out of the folder it was in here. The section stays:
    /// a kept folder goes to the end of the other's kept, a folder of
    /// today's to the top of its today's. The tabs go as moveTabs sends
    /// them, the same pages, or opened afresh in the other's sign-ins,
    /// which a card asks about first, as Dia's does (`ask`). The window
    /// stays; the corner says where it went, and its Go There goes there,
    /// as Arc's "Tab moved! Click to go there." Sync carries it as any
    /// tab's move. One step for ⌘Z puts it all back. `hand`: made by hand,
    /// for a move made a beat after the click (the menu's, on Arc's clock).
    @discardableResult
    func moveFolder(_ nest: Nest, to target: UUID, say: Bool = true, ask: Bool = true, hand: Bool? = nil) -> Bool {
        guard prefs.usesSpaces, target != spaceID, target != Space.mailID,
              let to = spaces.first(where: { $0.id == target }) else { return false }
        let byHand = hand ?? Browser.handMade
        let picked = tabs(in: nest).filter { sendable($0) && $0.everywhere == nil }
        let empty = folderBook.empties.filter { $0.within(nest) }
        guard !picked.isEmpty || !empty.isEmpty else { return false }
        let pages = picked.filter { !$0.shy && ($0.pending ?? $0.address) != nil }.count
        if ask, pages > 0, Spaces.store(for: spaceID) !== Spaces.store(for: target) {
            let question = Question(title: "Move \u{201C}\(nest.name)\u{201D} to \(to.name)?",
                                    detail: "\(to.name) has its own sign-ins. " + (pages == 1 ? "Its page opens" : "Its \(pages) pages open")
                                        + " again signed in as in \(to.name), so some may ask you to sign in.",
                                    glyph: "folder", space: to.well(prefs), yes: "Move")
            Task { @MainActor [weak self] in
                guard await Questions.shared.ask(question) else { return }
                self?.moveFolder(nest, to: target, say: say, ask: false, hand: byHand)
            }
            return true
        }
        let from = spaceID
        let was = nest.parent
        // The rows close up on Arc's spring.
        columnCurve = Self.folderLeaves
        // Not left for a laying long after, if the column isn't drawn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.columnCurve = nil }
        let move = sendFolder(nest, to: target)
        let back = { [weak self] in
            guard let self else { return }
            if spaceID != from { switchSpace(to: from) }
            if let move { undoMove(move) } else {
                nest.parent = was
                folderBook.send(empty, from: target, to: from)
            }
            folderBook.refresh()
            writeSession(now: true)
        }
        if byHand { did { back() } }
        if say {
            toaster.pop("Moved \(nest.name) to \(to.name)", mark: to.icon, undo: { [weak self] in
                self?.switchSpace(to: target)
            }, act: "Go There", feedback: .success)
        }
        return true
    }

    /// The folder's move itself, asked nothing and said nowhere (the
    /// agent's tabs.move takes it as it is): its tabs' move, which puts it
    /// back whole with undoMove, the folder it was in too; nil for a folder
    /// with no tabs, only empty folders, which go as they are.
    @discardableResult
    func sendFolder(_ nest: Nest, to target: UUID) -> SpaceMove? {
        settleNow()
        let from = spaceID
        let picked = tabs(in: nest).filter { sendable($0) && $0.everywhere == nil }
        if folderBook.naming == nest.id { folderBook.naming = nil }
        let was = nest.parent
        nest.parent = nil
        guard !picked.isEmpty else {
            folderBook.send(folderBook.empties.filter { $0.within(nest) }, from: from, to: target)
            folderBook.refresh()
            writeSession(now: true)
            return nil
        }
        var move = moveTabs(picked, to: target, say: false, step: false, top: nest.today)
        if let was { move?.cuts.append((nest, was)) }
        return move
    }

    /// Arc's folder leaving its space, filmed (docs/evidence/folder-motion-2026-10-16):
    /// the rows close the gap on a spring of 0.11 s, damping 1.
    static let folderLeaves = ColumnMotion.Curve.spring(response: 0.11, damping: 1.0)
    /// When the rows start closing up after the menu's line is picked: Arc's
    /// menu flashes and fades till 460 ms and the rows move at 500; the
    /// Mac's own menu hands its line over about 300 ms in.
    static let folderLeavesAfter: TimeInterval = 0.2

    /// The tabs into `target`'s row, parked; the tabs as they are there.
    private func send(_ moving: [Tab], pairs going: [Pair], from: UUID, to target: UUID, top: Bool = false) -> [Tab] {
        var row = parked[target] ?? loadRow(target)
        let same = Spaces.store(for: from) === Spaces.store(for: target)
        var map: [Tab.ID: Tab.ID] = [:]
        let arrived: [Tab] = moving.map { tab in
            // One an agent is at work in, or its own, is the same tab
            // there, page and all: the agent holds it by its id, mid-task,
            // and its cookies stay those it was signed in with. A call
            // too: opened afresh, it would drop.
            guard !same, !tab.bench, !Browser.hosts(tab), !tab.onCall, let url = tab.pending ?? tab.address else { map[tab.id] = tab.id; return tab }
            let fresh = carry(tab, url: url, into: target)
            map[tab.id] = fresh.id
            tab.close()
            return fresh
        }
        // The blank tab an empty space was given makes way for them.
        let blanks = row.tabs.filter { $0.isBlank && !$0.bench }
        row.tabs.removeAll { tab in blanks.contains { $0 === tab } }
        blanks.forEach { $0.close() }
        // Pins after its pins, the kept after its kept, the rest at its end.
        let after = row.tabs.lastIndex { $0.pin != nil }.map { $0 + 1 } ?? 0
        row.tabs.insert(contentsOf: arrived.filter { $0.pin != nil }, at: after)
        let kept = row.tabs.lastIndex { $0.pin != nil || $0.kept }.map { $0 + 1 } ?? 0
        row.tabs.insert(contentsOf: arrived.filter(\.kept), at: kept)
        let today = arrived.filter { $0.pin == nil && !$0.kept }
        if top {
            let head = row.tabs.lastIndex { $0.pin != nil || $0.kept }.map { $0 + 1 } ?? 0
            row.tabs.insert(contentsOf: today, at: head)
        } else {
            row.tabs.append(contentsOf: today)
        }
        row.pairs += going.compactMap { pair in
            guard let a = map[pair.first], let b = map[pair.second] else { return nil }
            return Pair(first: a, second: b, share: pair.share)
        }
        if row.active.map({ id in !row.tabs.contains { $0.id == id } }) ?? true { row.active = arrived.first?.id }
        parked[target] = row
        writeRow(row.tabs, active: row.active, space: target, pairs: row.pairs, now: true)
        return arrived
    }

    /// Whether a page, kept into `space`, has to be opened afresh there:
    /// its cookies are another store's, and a web view can't change store.
    /// A private page never is: it keeps its own store, whatever the row.
    func signsInAgain(_ tab: Tab, in space: UUID) -> Bool {
        guard !tab.shy else { return false }
        if let context = tab.page as? any PageSpaceContext {
            return !context.usesSignIns(of: space)
        }
        guard let web = tab.webKitOnly("Page profile relocation") else { return true }
        return web.configuration.websiteDataStore !== Spaces.store(for: space)
    }

    /// A small window's page kept into a space, the one on screen or
    /// another: the window goes to that space, and the page into its row as
    /// `takeIn` puts it, the same page when it is in the space's store and
    /// its address opened afresh there when not, since the page may have
    /// come up in another space than the one on screen now, or one deleted
    /// since. A page with no address yet becomes a blank tab of the
    /// space's. The page in the row now, for the flight to wait on; the
    /// one left outside, if another was made, is the caller's to let go.
    func takeIn(_ tab: Tab, into space: UUID) -> Tab {
        if space != spaceID { switchSpace(to: space) }
        // Wherever the window is now, if it couldn't go there.
        let target = spaceID
        guard signsInAgain(tab, in: target) else {
            takeIn(tab)
            return tab
        }
        let fresh = Tab(configuration: Web.configuration(store: Spaces.store(for: target)))
        prepare(fresh)
        if let url = tab.pending ?? tab.address { fresh.go(to: url) }
        takeIn(fresh)
        return fresh
    }

    /// A link a page opens in a new tab (a ⌘-click, a middle click,
    /// target=_blank, a mail's link, a peek opened as a tab) to a site a
    /// rule keeps in another space (LinkRoutes.pageLinkSpace): opened
    /// there, in that space's sign-ins, as Arc's Air Traffic Control sends
    /// it. In front, the window goes with it. Behind, it waits at the top
    /// of that space's today's, the window stays, and the corner says
    /// where it went, since nothing on screen does. False when it stays
    /// here, for the caller's own new tab.
    @discardableResult
    func routePageLink(_ url: URL, from source: Tab?, foreground: Bool) -> Bool {
        guard let target = LinkRoutes.shared.pageLinkSpace(for: url, from: source, in: self),
              let to = spaces.first(where: { $0.id == target }) else { return false }
        if foreground {
            // After WebKit's question is answered: the switch parks the
            // page that asked, which is still in the middle of asking.
            DispatchQueue.main.async { [weak self, weak source] in
                guard let self else { return }
                switchSpace(to: target)
                if spaceID == target { open(url, foreground: true) } else { open(url, foreground: true, from: source, linked: true) }
            }
            return true
        }
        let tab = Tab(configuration: Web.configuration(store: Spaces.store(for: target)))
        prepare(tab)
        tab.restore(url: url, title: "")
        if source?.bench == false { tab.prepareVideoOpening(url) }
        var row = parked[target] ?? loadRow(target)
        // The blank tab an empty space was given makes way for it.
        let blanks = row.tabs.filter { $0.isBlank && !$0.bench }
        row.tabs.removeAll { tab in blanks.contains { $0 === tab } }
        blanks.forEach { $0.close() }
        // Where a new tab of that space's goes: the top of its today's,
        // or the end of the strip with the tabs across the top.
        let head = prefs.sidebar ? (row.tabs.lastIndex { $0.pin != nil || $0.kept }.map { $0 + 1 } ?? 0) : row.tabs.count
        row.tabs.insert(tab, at: head)
        if row.active.map({ id in !row.tabs.contains { $0.id == id } }) ?? true { row.active = tab.id }
        parked[target] = row
        writeRow(row.tabs, active: row.active, space: target, pairs: row.pairs, now: true)
        toaster.pop("Opened in \(to.name)", mark: to.icon, undo: { [weak self] in
            self?.switchSpace(to: target)
        }, act: "Go There")
        return true
    }

    /// A tab's page, asleep in another space's store, with its pin and name.
    private func carry(_ tab: Tab, url: URL, into space: UUID) -> Tab {
        let fresh = Tab(configuration: Web.configuration(store: Spaces.store(for: space)))
        prepare(fresh)
        fresh.restore(url: url, title: tab.title)
        fresh.pin = tab.pin
        fresh.name = tab.name
        fresh.kept = tab.kept
        fresh.nest = tab.nest
        return fresh
    }

    /// Undo: the tabs back where they stood, and the one in front again.
    func undoMove(_ move: SpaceMove) {
        guard spaceID == move.from, var row = parked[move.to] else { return }
        // Back in the folders they left first: a page opened afresh carries it.
        for moved in move.tabs { if let nest = move.unnested[moved.original] { moved.now.nest = nest } }
        for cut in move.cuts { cut.nest.parent = cut.parent }
        folderBook.send(move.empties, from: move.to, to: move.from)
        let ids = Set(move.tabs.map(\.now.id))
        let back = move.tabs.filter { moved in row.tabs.contains { $0 === moved.now } }
        guard !back.isEmpty else { return }
        let going = row.pairs.filter { ids.contains($0.first) && ids.contains($0.second) }
        row.tabs.removeAll { ids.contains($0.id) }
        row.pairs.removeAll { ids.contains($0.first) || ids.contains($0.second) }
        if let active = row.active, ids.contains(active) { row.active = nil }
        parked[move.to] = row
        writeRow(row.tabs, active: row.active, space: move.to, pairs: row.pairs, now: true)

        let same = Spaces.store(for: move.from) === Spaces.store(for: move.to)
        var map: [Tab.ID: Tab.ID] = [:]
        var home: [(Tab, Int, Tab.ID)] = back.compactMap { moved in
            if let was = move.homes[moved.original] {
                if moved.now.bench { moved.now.assistantSpace = was } else { moved.now.stays = false }
                map[moved.now.id] = moved.now.id
                return (moved.now, moved.at, moved.original)
            }
            if same { map[moved.now.id] = moved.now.id; return (moved.now, moved.at, moved.original) }
            guard let url = moved.now.pending ?? moved.now.address else { return nil }
            let fresh = carry(moved.now, url: url, into: move.from)
            moved.now.close()
            map[moved.now.id] = fresh.id
            return (fresh, moved.at, moved.original)
        }
        home.sort { $0.1 < $1.1 }
        var row2 = tabs
        for (tab, at, _) in home { row2.insert(tab, at: min(at, row2.count)) }
        lay(row2)
        pairs += going.compactMap { pair in
            guard let a = map[pair.first], let b = map[pair.second] else { return nil }
            return Pair(first: a, second: b, share: pair.share)
        }
        if let was = move.wasActive, let tab = home.first(where: { $0.2 == was })?.0 { select(tab) }
        else if !tabs.contains(where: { $0.id == activeID }), let first = tabs.first { select(first) }
        rememberSession()
    }

    /// A space's pages, its row's if it has been opened since launch, its
    /// file's if not. Blank tabs and agents' aren't pages of its own, nor
    /// the shared pins, every space's.
    func pages(in id: UUID) -> [(url: URL, title: String)] {
        if id == spaceID || parked[id] != nil {
            let row = id == spaceID ? tabs : parked[id]?.tabs ?? []
            return row.compactMap { tab in
                guard !tab.bench, !tab.shy, tab.everywhere == nil, let url = tab.pending ?? tab.address, Session.writes(url) else { return nil }
                return (url, tab.title)
            }
        }
        // In a window other than the first, a space's list is every
        // window's, as loadRow joins it: a tab another window moved there
        // is counted before this window opens the space (feedback #1808).
        var saved = Session.read(space: id, window: windowID)
        if id != Space.pinsID, let list = sharedKept(for: id) { saved = KeptEverywhere.joined(saved, list: list).shape }
        return saved.tabs.compactMap { entry in URL(string: entry.url).map { ($0, entry.title) } }
    }

    /// How many pages a space has, as Settings and the tray say it: from its
    /// row when it has been opened since launch, and from its file, read
    /// once, when not; a view asking as it draws never reads the disk again
    /// until the file changes (writeRow).
    func pageCount(in id: UUID) -> Int {
        if id == spaceID || parked[id] != nil { return pages(in: id).count }
        if let known = Spaces.pageCounts[id] { return known }
        let count = pages(in: id).count
        Spaces.pageCounts[id] = count
        return count
    }

    /// Spaces turned off: back to the first one. The others are kept, in
    /// case they are turned on again.
    func leaveSpaces() {
        guard windowPurpose == .normal else { return }
        let home = homeSpaceID
        guard spaceID != home else { return }
        let was = prefs.usesSpaces
        // On for the one switch only: the pins don't turn with it.
        Spaces.leaving = true
        prefs.usesSpaces = true
        switchSpace(to: home)
        prefs.usesSpaces = was
        Spaces.leaving = false
        for (space, row) in parked {
            writeRow(row.tabs, active: row.active, space: space, pairs: row.pairs, now: true)
            row.tabs.forEach { $0.close() }
        }
        parked = [:]
    }
}

// MARK: - the icon

/// The few questions a space's menu asks, in the app's own card over the page.
@MainActor
enum SpaceAsk {
    /// Its name, in a line to type into, the old one picked to be typed over.
    static func name(_ space: Space, browser: Browser, then: @escaping (String) -> Void) {
        let field = Question.Field(space.name, prompt: "Name")
        let question = Question(title: "Rename \(space.name)", glyph: "character.cursor.ibeam",
                                space: space.well(browser.prefs),
                                yes: "Rename", field: field)
        Task { @MainActor in
            guard await Questions.shared.ask(question), !field.trimmed.isEmpty, field.trimmed != space.name else { return }
            then(field.trimmed)
        }
    }
}

// MARK: - the glide after a sideways swipe

/// The trackpad's glide after fingers lift from a sideways swipe the
/// column took. The catch let it through: lifted while drifting down, the
/// glide scrolled the rows of the space being left as the row of spaces
/// slid, and the column seemed stuck. A swipe that turned the space keeps
/// its glide too, until the glide ends or fingers come down again.
struct SwipeGlide {
    /// The glide coming is a sideways swipe's, the column's to hold back.
    private(set) var held = false

    /// The fingers lifted: `sideways` when the swipe was the column's.
    mutating func lifted(sideways: Bool) { held = sideways }

    /// Whether this event is the held glide's, to be swallowed.
    mutating func takes(phase: NSEvent.Phase, momentum: NSEvent.Phase) -> Bool {
        if phase == .began || phase == .mayBegin {
            held = false
            return false
        }
        guard held, momentum != [] else { return false }
        if momentum == .ended || momentum == .cancelled { held = false }
        return true
    }
}

/// A swipe's end, owed to the rows when they heard its began. A began with
/// no move in it goes on to the rows before the catch knows which way the
/// fingers go, and their scroll view opens a gesture. When the moves after
/// it go sideways the catch takes them, but taking the end too would leave
/// that gesture open.
struct SwipeEnd {
    /// The rows heard this swipe's began and wait for its end.
    private(set) var owed = false

    /// Fingers down: `passed` when the began went on to the rows.
    mutating func began(passed: Bool) { owed = passed }

    /// The swipe ended or was cancelled: whether its end goes on to the
    /// rows, even when the catch took its moves. Owed once only.
    mutating func ended() -> Bool {
        defer { owed = false }
        return owed
    }
}

// MARK: - two fingers sideways

/// Laid behind the column: two fingers sideways over it go to the next
/// space or back, one a gesture. Vertical scrolls, and the rows' own drags,
/// are left alone.
struct SpaceSwipe: NSViewRepresentable {
    /// What the column's catch made of the last gestures, for the bench.
    @MainActor static var trace: [String] = []
    @MainActor static func note(_ line: @autoclosure () -> String) {
        guard Store.testing else { return }
        trace.append(line())
        if trace.count > 40 { trace.removeFirst(trace.count - 40) }
    }

    /// The bench's "before": a mouse's wheel over the column let through,
    /// as it was until #282. Test runs only.
    @MainActor static var wheelOff = false

    /// The column's catches in their windows (Catch.viewDidMoveToWindow).
    @MainActor private static let columns = NSHashTable<Catch>.weakObjects()

    /// A swipe begun over the column is the column's, even where a pane
    /// lies under it: mail's pane runs under the column brought out over it
    /// as a card, and took the swipe there for mail's back and forward
    /// (MailSwipe), the row of spaces caught and left still (feedback #158).
    @MainActor static func claims(_ event: NSEvent) -> Bool {
        columns.allObjects.contains { catcher in
            catcher.column && catcher.acceptsInput && catcher.window === event.window
                && catcher.bounds.contains(catcher.convert(event.locationInWindow, from: nil))
        }
    }

    let browser: Browser
    /// Over the column: its spaces slide as one row (SpacePager). The
    /// strip's tabs follow the fingers on their own (SpacePull).
    var column = false

    func makeNSView(context: Context) -> Catch {
        let view = Catch()
        view.browser = browser
        view.column = column
        return view
    }

    func updateNSView(_ view: Catch, context: Context) {
        view.browser = browser
        view.column = column
    }

    final class Catch: NSView {
        weak var browser: Browser?
        var column = false
        /// This gesture moves the column's row of spaces.
        private var paging = false
        /// The row of spaces couldn't come up for this gesture (Reduce
        /// Motion, a column with nothing laid out yet): the rows stay as
        /// they are and the space changes when the fingers lift, if they
        /// went far enough. The old way, its rows fading out, had nothing
        /// coming under them any more.
        private var unpaged = false
        private var monitor: Any?
        private var spaceButtons = Set<Int>()
        private var travel: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The column moves its drawing offscreen without hiding its native
        /// subtree. Local monitors must follow that visibility too (#1530).
        var acceptsInput: Bool {
            window != nil && !isHiddenOrHasHiddenAncestor
                && (!column || browser?.column?.shown == true)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            SpaceSwipe.columns.add(self)
            spaceButtons.removeAll()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseDown, .otherMouseUp, .swipe]) { [weak self] event in
                // Not `self?.heard(event) ?? event`: optional chaining
                // folds heard's nil, the event taken, into self's, and the
                // `??` handed every taken event back. A sideways swipe's
                // moves, its drift up or down too, went on to the rows of
                // the space being left, which scrolled under the fingers.
                AppKitMainThread.sync {
                    guard let self else { return event }
                    return self.heard(event)
                }
            }
        }

        /// One gesture, judged once: whether it began over the column and
        /// which way it went. Only a sideways one that began here is taken,
        /// and all of it; anything else, a page's scroll drifting over the
        /// column, the rows' own vertical scroll, goes on untouched.
        private var owned = false
        /// The last few moves, when and how far: how fast the fingers were
        /// going as they lifted.
        private var recent: [(TimeInterval, CGFloat)] = []

        /// Still going the way they went, quickly, in the last 60 ms.
        private func flicked() -> Bool {
            guard let first = recent.first, let last = recent.last, last.0 > first.0 else { return false }
            let speed = recent.map(\.1).reduce(0, +) / CGFloat(last.0 - first.0)
            return abs(speed) > 600 && (speed < 0) == (travel < 0)
        }
        private var sideways: Bool?
        /// The glide after a sideways swipe, held back (SwipeGlide).
        private var glide = SwipeGlide()
        private var end = SwipeEnd()

        /// Fingers down again on a gesture whose end never came here, gone
        /// to another window or another app (a swipe of three fingers to
        /// another desktop): the strip's tabs go back, as a lift short of
        /// halfway sends them. The column's row lets itself go
        /// (SpacePager.lost).
        private func lose() {
            guard owned, sideways == true, !paging, !unpaged, !column else { return }
            MainActor.assumeIsolated { SpacePull.shared.cancel() }
        }

        /// A mouse's wheel sideways over the column (SpaceWheel).
        private var wheel = SpaceWheel()

        /// A wheel's move, with no gesture around it: a clicking wheel's
        /// notch, or a smooth mouse's phaseless points. Sideways over the
        /// column, the next space or back, as a key turns it; up or down,
        /// the rows' own scroll. Before #282 every one of them was let
        /// through for the trackpad's phases only, and a mouse's wheel
        /// sideways did nothing over the column.
        private func wheeled(_ event: NSEvent) -> NSEvent? {
            let move = SpaceWheel.Move(event)
            guard SpaceWheel.across(move) != nil else {
                // Up or down: the rows' scroll, and the end of a push.
                if move.dx != 0 || move.dy != 0 { wheel.reset() }
                return event
            }
            let taken = MainActor.assumeIsolated { () -> Int? in
                guard !SpaceSwipe.wheelOff, let browser, browser.swipesSpaces, !SpacePager.shared.holding,
                      bounds.contains(convert(event.locationInWindow, from: nil)),
                      // The island's own: its swipe swaps players (BandView.claims).
                      !BandView.claims(event) else {
                    wheel.reset()
                    return nil
                }
                guard let step = wheel.take(move) else { return nil }
                SpaceSwipe.note("wheel dx=\(move.dx) dy=\(move.dy) precise=\(move.precise) shift=\(move.shift) step=\(step) t=\(String(format: "%.3f", move.time))")
                guard step != 0 else { return 0 }
                // One space, never round past the ends, as two fingers go.
                let order = browser.turnOrder
                if let here = order.firstIndex(where: { $0.id == browser.spaceID }), order.indices.contains(here + step) {
                    browser.switchSpace(to: order[here + step].id)
                }
                return step
            }
            return taken == nil ? event : nil
        }

        func heard(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }
            // Side buttons over the visible sidebar switch spaces (#1721).
            // The page keeps its own Back/Forward; a consumed press owns its
            // release even if the pointer has left the sidebar meanwhile.
            if event.type == .otherMouseUp {
                guard spaceButtons.remove(event.buttonNumber) != nil else { return event }
                return nil
            }
            if event.type == .otherMouseDown || event.type == .swipe {
                // Mouse drivers can send Back/Forward as a discrete swipe
                // instead of a side button. This is not a scroll-wheel or
                // trackpad paging gesture; use the same Space action.
                let step: Int
                if event.type == .swipe {
                    guard event.deltaX != 0 else { return event }
                    step = event.deltaX > 0 ? -1 : 1
                } else {
                    guard event.buttonNumber == 3 || event.buttonNumber == 4 else { return event }
                    step = event.buttonNumber == 3 ? -1 : 1
                }
                guard column, acceptsInput, let browser, browser.prefs.usesSpaces,
                      browser.turnOrder.count > 1, !SpacePager.shared.holding,
                      bounds.contains(convert(event.locationInWindow, from: nil)),
                      !BandView.claims(event) else { return event }
                if event.type == .swipe || spaceButtons.insert(event.buttonNumber).inserted {
                    browser.stepSpace(step)
                }
                return nil
            }
            guard acceptsInput else {
                lose()
                owned = false
                sideways = nil
                paging = false
                unpaged = false
                travel = 0
                recent = []
                wheel.reset()
                glide = SwipeGlide()
                end = SwipeEnd()
                return event
            }
            if column, event.phase == [], event.momentumPhase == [] { return wheeled(event) }
            guard Swipe.isGesture(event) else { return event }
            if glide.takes(phase: event.phase, momentum: event.momentumPhase) { return nil }
            if column, event.phase == .began || event.phase == .ended || event.phase == .cancelled {
                MainActor.assumeIsolated {
                    SpaceSwipe.note(event.phase == .began
                        ? "began inside=\(bounds.contains(convert(event.locationInWindow, from: nil)))"
                        : "end owned=\(owned) sideways=\(sideways.map { "\($0)" } ?? "-") paging=\(paging) travel=\(Int(travel))")
                }
            }
            switch event.phase {
            case .mayBegin:
                // Fingers resting, not yet moving: the gesture before is
                // over, its end heard or not.
                lose()
                owned = false
                paging = false
                unpaged = false
                end = SwipeEnd()
                return event
            case .began:
                lose()
                // Goes on to the rows unless taken below, sideways.
                end.began(passed: true)
                owned = browser?.swipesSpaces == true
                    && bounds.contains(convert(event.locationInWindow, from: nil))
                    // Begun on the island: that swipe swaps players, or
                    // scrubs what plays (BandView.claims).
                    && !MainActor.assumeIsolated { BandView.claims(event) }
                sideways = nil
                travel = 0
                recent = []
                paging = false
                unpaged = false
            case .changed:
                break
            default:
                // Ended, cancelled, or the momentum after: the gesture is over.
                let mine = owned && sideways == true
                // When the rows heard the began, this end closes their
                // gesture, even when the catch took the moves (SwipeEnd).
                var owed = false
                if event.phase == .ended || event.phase == .cancelled {
                    owned = false
                    owed = end.ended()
                    glide.lifted(sideways: mine)
                    // The row of spaces goes on the way the fingers went,
                    // or to whichever shows more (SpacePaging).
                    if mine, paging {
                        paging = false
                        let speed = SpacePaging.speed(recent.map { ($0.0, Double($0.1)) }, liftedAt: event.timestamp)
                        MainActor.assumeIsolated { SpacePager.shared.release(speed: CGFloat(speed)) }
                        return owed ? event : nil
                    }
                    // Gone quiet before lifting is no flick.
                    recent.removeAll { event.timestamp - $0.0 > 0.06 }
                    if mine, unpaged, let browser {
                        unpaged = false
                        let flick = flicked()
                        let travelled = travel
                        let way = travel < 0 ? 1 : -1
                        MainActor.assumeIsolated {
                            let far = abs(travelled) / SpacePull.reach
                            guard far >= SpacePull.enough || (flick && far >= SpacePull.flickEnough) else { return }
                            let order = browser.turnOrder
                            // One space, never round past the ends, as the row goes.
                            if let here = order.firstIndex(where: { $0.id == browser.spaceID }), order.indices.contains(here + way) {
                                browser.switchSpace(to: order[here + way].id)
                            }
                        }
                        return owed ? event : nil
                    }
                    if mine, let browser {
                        // Across the top, any way toward a neighbor brings
                        // it, at once; at an end it springs back (StripTurn).
                        MainActor.assumeIsolated { SpacePull.shared.release(browser) }
                    }
                }
                return mine && event.momentumPhase == [] && !owed ? nil : event
            }
            guard owned else { return event }
            if sideways == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
                sideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            }
            guard sideways == true, let browser else { return event }
            // Every way on from here takes the event, a sideways began too.
            if event.phase == .began { end.began(passed: false) }
            travel += event.scrollingDeltaX
            // Timed by the trackpad, not as they arrive: moves held up
            // behind a busy frame come in a bunch and would read as a flick.
            recent.append((event.timestamp, event.scrollingDeltaX))
            recent.removeAll { event.timestamp - $0.0 > 0.06 }
            let travelled = travel
            // Over the column its spaces slide as one row, under the
            // fingers, the window's color with them.
            if column, !paging, !unpaged, travel != 0 {
                paging = MainActor.assumeIsolated { SpacePager.shared.grab(browser, by: event) }
                unpaged = !paging
                MainActor.assumeIsolated { SpaceSwipe.note("grab \(paging) \(SpacePager.refusal(browser) ?? "")") }
            }
            if paging {
                MainActor.assumeIsolated { SpacePager.shared.follow(travelled) }
                return nil
            }
            if unpaged { return nil }
            MainActor.assumeIsolated {
                // All the way, it holds there: the space comes when the
                // fingers lift, as a page's swipe back does, never while
                // they are still moving, which is when a frame spent laying
                // out its row would be felt.
                SpacePull.shared.follow(travelled, browser: browser)
            }
            return nil
        }
    }
}

/// Where the main thread's time goes in a change of space, for `bench pace`:
/// a mark at each step of `switchSpace` (and of SpacePager's turn), then
/// the end of the run-loop pass it happened in (SwiftUI's update of the
/// window and Core Animation's commit), and of the next two. Each mark is
/// [step, ms since the switch began, ms of the main thread's CPU since].
/// Off unless a bench run turns it on.
@MainActor
enum SwitchMeter {
    static var on = false
    private(set) static var marks: [(String, Double, Double)] = []
    /// Rows of the column made since the switch began (SideRow).
    static var made = 0
    /// Of them, rows of the pager's pictured pages (SideRow, closes false).
    static var pagerMade = 0
    /// Rows of the column drawn again since the switch began (SideRow).
    static var rowBodies = 0
    static func countRow() { if on { rowBodies += 1 } }
    /// What drew in the switch, counted by what it was and why (bench).
    static var notes: [String: Int] = [:]
    static func note(_ what: @autoclosure () -> String) { if on, began > 0 { notes[what(), default: 0] += 1 } }
    private static var began = 0.0
    private static var cpu = 0.0

    static func start() {
        guard on else { return }
        began = CACurrentMediaTime()
        cpu = Bench.mainCPU()
        marks = []
        made = 0
        pagerMade = 0
        notes = [:]
        rowBodies = 0
        // After every other observer of the pass: SwiftUI's flush and the
        // commit come before it, so this is when the pass ended.
        var passes = 0
        var woke = true
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, Int.max) { observer, activity in
            MainActor.assumeIsolated {
                if activity == .afterWaiting { woke = true; return }
                guard woke else { return }
                woke = false
                passes += 1
                mark(passes == 1 ? "pass" : "pass \(passes)")
                // When the row's spring was sent off, as its commit stamped it.
                if passes == 1, let slid = SpacePager.shared.slideBegan, slid >= began {
                    marks.append(("slid", ((slid - began) * 10000).rounded() / 10, -1))
                }
                if passes >= 3, let observer {
                    // How many of the column's rows were made anew.
                    marks.append(("rows made", Double(made), -1))
                    marks.append(("pager rows made", Double(pagerMade), -1))
                    marks.append(("row bodies", Double(rowBodies), -1))
                    for (what, count) in notes.sorted(by: { $0.key < $1.key }) { marks.append(("note " + what, Double(count), -1)) }
                    CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    static func mark(_ step: String) {
        guard on, began > 0 else { return }
        marks.append((step, ((CACurrentMediaTime() - began) * 10000).rounded() / 10, ((Bench.mainCPU() - cpu) * 10).rounded() / 10))
    }

    static var report: [[Any]] { marks.map { [$0.0, $0.1, $0.2] } }
}
