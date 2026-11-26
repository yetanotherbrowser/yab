import AppKit
import Combine
import SwiftUI
import SyncKit

// What the field does beside finding places: the places of its own that Tab
// goes into, Clipboard History and Emoji; a sum worked out as it is typed;
// what can be done to the page ⌘L raised it over; and every row's actions,
// ↩ for the first and ⌘K for the rest.

/// A place of the field's own, gone into with its name and Tab, as a site
/// is (see Scopes), and left with ⌫ in the empty field or Escape. Each but
/// Emoji is a list with the chosen one beside it (PlaceView, ClipPlace).
enum FieldPlace: String, Equatable, CaseIterable {
    case clipboard, emoji, downloads, passwords, autofill, history, bookmarks, chats, routines, files
    /// Words kept to write again (Snippets.swift), ⌘;.
    case snippets
    /// Text selected on the page, and what can be done to it: ⌘J.
    case selection
    /// Mail: the chosen thread's actions, threads by their words (MailField).
    case mail
    /// Boosts and plugins to try on your page (StoreCatalog, docs/store.md).
    case store
    /// All of Now, past the four the plain list has room for.
    case now
    /// What you pay for and have coming, read from mail (Purchases).
    case purchases

    var title: String {
        switch self {
        case .clipboard: return "Clipboard History"
        case .emoji: return "Emoji"
        case .downloads: return "Files"
        case .passwords: return "Passwords"
        case .autofill: return "Autofill"
        case .history: return "History"
        case .bookmarks: return "Bookmarks"
        case .chats: return "Chats"
        case .routines: return "Routines"
        case .snippets: return "Snippets"
        case .files: return "Files"
        case .selection: return "Selection"
        case .mail: return "Mail"
        case .store: return "Store"
        case .now: return "Now"
        case .purchases: return "Purchases"
        }
    }

    /// Its name in the field's chip.
    var short: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .autofill: return "Autofill"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: return "clipboard"
        case .emoji: return "face.smiling"
        case .downloads: return "arrow.down.circle"
        case .passwords: return "key"
        case .autofill: return "creditcard"
        case .history: return "clock"
        case .bookmarks: return "bookmark"
        case .chats: return "bubble"
        case .routines: return "clock.arrow.circlepath"
        case .snippets: return "character.cursor.ibeam"
        case .files: return "doc.badge.plus"
        case .selection: return "spark"
        case .mail: return "envelope"
        case .store: return "storefront"
        case .now: return "clock.circle"
        case .purchases: return "bag"
        }
    }

    /// Its tile's color, Settings' for the same feature.
    var tint: NSColor {
        switch self {
        case .clipboard: return .systemBlue
        case .emoji: return .systemYellow
        case .downloads: return .systemTeal
        case .passwords: return .systemGray
        case .autofill: return .systemGreen
        case .history: return .systemOrange
        case .bookmarks: return .systemIndigo
        case .chats: return .systemPurple
        // Settings' Routines tile.
        case .routines: return .systemPink
        // Settings' Snippets tile.
        case .snippets: return .systemOrange
        case .files: return .systemTeal
        // Settings' Commands tile.
        case .selection: return .systemPurple
        case .mail: return .systemCyan
        case .store: return .systemOrange
        case .now: return .systemRed
        case .purchases: return .systemGreen
        }
    }

    /// What the empty field says in it.
    var placeholder: String {
        switch self {
        case .clipboard: return "Type to filter entries…"
        case .emoji: return "Search for emoji…"
        case .downloads: return "Search files and what’s in them…"
        case .passwords: return "Search passwords…"
        case .autofill: return "Search you, cards and addresses…"
        case .history: return "Search history…"
        case .bookmarks: return "Search bookmarks…"
        case .chats: return "Search chats…"
        case .routines: return "Search routines…"
        case .snippets: return "Search snippets…"
        case .files: return "Find a file on this Mac…"
        case .selection: return "Ask about the selection…"
        case .mail: return "Search mail, or a command…"
        case .store: return "Find a boost or describe a change…"
        case .now: return "Type to filter…"
        case .purchases: return "Search purchases…"
        }
    }

    /// The kinds its list can be narrowed to, from the field's end; ⌘P
    /// steps through them. Clipboard History has its own (Clips.Filter).
    var filters: [String] {
        switch self {
        case .downloads: return ["All Files", "Downloaded", "From Mail", "Sent by You", "Images", "Documents"]
        case .passwords: return ["All Accounts", "Used Lately", "With Codes", "Leaked", "Reused", "Weak"]
        case .autofill: return ["Everything", "You", "Cards", "Addresses"]
        case .history: return ["All Time", "Today", "This Week", "By Thread"]
        case .now: return ["All Kinds", "Promises", "Mail", "Meetings", "Agents", "Copied", "From iPhone"]
        case .purchases: return ["Subscriptions", "On the Way", "Receipts"]
        default: return []
        }
    }

    /// History's filter that lists threads, not pages (docs/day-threads.md).
    static let byThread = 3

    /// What typed, whole or begun, names it.
    var names: [String] {
        switch self {
        case .clipboard: return ["clipboard history", "clipboard", "clip", "copied"]
        case .emoji: return ["emoji", "emojis"]
        case .downloads: return ["downloads", "download", "files"]
        case .passwords: return ["passwords", "password", "logins", "keychain"]
        case .autofill: return ["autofill", "cards and addresses", "cards", "addresses", "credit card", "profile", "about me"]
        case .history: return ["history", "visited"]
        case .bookmarks: return ["bookmarks", "bookmark", "favorites"]
        case .chats: return ["chats", "chat", "agents"]
        case .routines: return ["routines", "routine"]
        case .snippets: return ["snippets", "snippet", "text replacement"]
        case .mail: return ["mail", "inbox", "gmail"]
        case .store: return ["store", "boosts", "boost", "plugins"]
        case .now: return ["now"]
        case .purchases: return ["purchases", "subscriptions", "receipts", "orders", "packages", "deliveries"]
        case .files, .selection: return []
        }
    }

    /// The place a command opens, now that its key opens the place.
    static func of(_ command: Command) -> FieldPlace? {
        switch command {
        case .history: return .history
        case .downloads: return .downloads
        case .passwords: return .passwords
        case .autofill: return .autofill
        case .bookmarks: return .bookmarks
        case .boostStore: return .store
        default: return nil
        }
    }

    /// A command's row as its place's, or the row as it is.
    @MainActor static func row(for offer: Suggestion, in browser: Browser) -> Suggestion {
        guard case .command(let command) = offer.kind, let place = of(command) else { return offer }
        return Suggestion(key: place.title, title: browser.placeDetail(place), url: nil, kind: .place(place))
    }

    /// The key that opens it from anywhere, if it has one (Keymap).
    var shortcut: Shortcut.Action? {
        switch self {
        case .clipboard: return .clipboard
        case .emoji: return .emoji
        case .autofill: return .autofill
        case .chats: return .chats
        case .routines: return .routines
        case .store: return .boostStore
        case .now: return .now
        case .purchases: return .purchases
        case .history: return .history
        case .downloads: return .downloads
        case .passwords: return .passwords
        case .bookmarks: return .bookmarks
        case .snippets: return .snippets
        default: return nil
        }
    }

    /// Page selection and file dialogs require their own context. Mail's
    /// existing shortcut toggles its space rather than opening this place.
    static func opened(by shortcut: Shortcut.Action) -> FieldPlace? {
        allCases.first { $0.shortcut == shortcut }
    }

    /// The place the words name, begun far enough to be meant: three
    /// letters, or all of the name.
    static func named(_ typed: String) -> FieldPlace? {
        let words = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard words.count >= 3 else { return nil }
        return allCases.first { place in place != .files && place.offered && place.names.contains { $0.hasPrefix(words) } }
    }

    /// Mail is offered only once an account is connected.
    var offered: Bool {
        switch self {
        // Read from mail: offered once an account is connected, as Mail is.
        case .mail, .purchases: return MailExperiment.enabled() && !(Store.settings.stringArray(forKey: "mail.accounts") ?? []).isEmpty
        default: return true
        }
    }

    /// Whether it can be kept among Favorites (FieldFavorites): all but the
    /// two about the page under the field, its selection and its file box.
    var keeps: Bool { self != .selection && self != .files }
}

/// One thing a row can have done to it: ↩ does the first, featured actions
/// also appear in the foot, and ⌘K lists them all.
struct FieldAction: Identifiable {
    let id: String
    let title: String
    var keys: String = ""
    var symbol: String = "arrow.up.right"
    /// An additional action worth showing beside Return in the field's foot.
    var featured = false
    /// Its part of ⌘K's menu: longer lists leave space between parts.
    var group = 0
    /// Something outside the app it goes to, drawn as that thing is, as a
    /// launcher's actions wear them: the app a file opens in, the Finder,
    /// a folder, a site's own icon (ActionIcons). Nil for the app's own mark.
    var image: NSImage? = nil
    /// What is chosen now, in a list of choices (where Files looks): a tick
    /// where the keys would be.
    var checked = false
    /// Muted words where the keys would be, in a list of choices: how many
    /// visits a site has.
    var note = ""
    /// Can't be taken back, or takes many at once: its words in the red
    /// of what cannot be undone, where the foot shows it.
    var danger = false
    let run: @MainActor () -> Void

    var shortcut: Shortcut.Action? {
        guard !keys.isEmpty else { return nil }
        switch id {
        case "pin": return .fieldPin
        case "page", "link": return .fieldPage
        case "second", "copylink": return .fieldSecond
        case "reveal": return .fieldReveal
        case "code": return .fieldCode
        case "show": return .fieldShow
        case "edit": return .fieldEdit
        case "new": return .fieldNew
        case "delete": return .fieldDelete
        case "clear": return .fieldClear
        case "copy", "behind": return .fieldCopy
        case "plain", "later": return .fieldAlternate
        case "movehere", "instant": return .fieldMove
        case "ahead": return .fieldAhead
        case "forget": return .fieldForget
        case "done": return .fieldDone
        case "hand": return .fieldDo
        case "favorite": return .fieldFavorite
        case "moveup": return .fieldFavoriteUp
        case "movedown": return .fieldFavoriteDown
        default: return nil
        }
    }

    @MainActor var shownKeys: String {
        if let shortcut { return Keymap.shared.keys(shortcut)?.text ?? "" }
        return keys
    }
}

// MARK: - emoji

/// Every emoji this Mac draws, found by its name and CLDR's English words
/// for it, and by what it means (EmojiMeaning.swift). Made once, the first
/// time the field asks.
enum Emoji {
    struct One: Hashable {
        let glyph: String
        let name: String
        /// Every word it is found by, lower case.
        let words: [String]
        /// The part of the grid it is listed in.
        var section = ""
    }

    /// The Unicode blocks the grid lists, in order, each under its heading.
    static let blocks: [(String, ClosedRange<UInt32>)] = [
        ("Smileys & Emotion", 0x1F600...0x1F64F),
        ("People & Fantasy", 0x1F90C...0x1F9FF),
        ("Nature, Food & Things", 0x1F300...0x1F5FF),
        ("Travel & Places", 0x1F680...0x1F6FF),
        ("Objects", 0x1FA70...0x1FAFF),
        ("Symbols", 0x2600...0x27BF),
    ]

    static let all: [One] = {
        var out: [One] = []
        var seen: Set<String> = []
        func one(_ glyph: String, name: String) -> One {
            let bare = bare(glyph)
            let english = [name] + (cldr[bare] ?? [])
            let words = english.flatMap { $0.lowercased().split(separator: " ").map(String.init) }
            // Its part: the block its first scalar is in, the people's for
            // one joined of several with none of its own.
            let first = glyph.unicodeScalars.first?.value ?? 0
            let section = blocks.first { $0.1.contains(first) }?.0 ?? "People & Fantasy"
            return One(glyph: glyph, name: cldr[bare]?.first ?? name, words: Array(NSOrderedSet(array: words)) as! [String], section: section)
        }
        for (_, range) in blocks {
            for code in range {
                guard let scalar = Unicode.Scalar(code), scalar.properties.isEmoji,
                      let name = scalar.properties.name?.lowercased() else { continue }
                // Regional letters are halves of flags, not emoji to pick.
                if (0x1F1E6...0x1F1FF).contains(code) { continue }
                let glyph = scalar.properties.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
                guard !seen.contains(glyph) else { continue }
                seen.insert(glyph)
                out.append(one(glyph, name: name))
            }
        }
        // The joined ones CLDR names, 🧑‍💻 ❤️‍🔥, where this Mac knows each part.
        for (glyph, words) in cldrInOrder where glyph.unicodeScalars.contains("\u{200D}") {
            guard glyph.unicodeScalars.allSatisfy({ $0.properties.isEmoji || $0 == "\u{200D}" }) else { continue }
            var shown = ""
            for scalar in glyph.unicodeScalars {
                shown.unicodeScalars.append(scalar)
                if scalar != "\u{200D}", !scalar.properties.isEmojiPresentation, !scalar.properties.isEmojiModifier {
                    shown.unicodeScalars.append("\u{FE0F}")
                }
            }
            guard !seen.contains(shown) else { continue }
            seen.insert(shown)
            out.append(one(shown, name: words.first ?? glyph))
        }
        return out
    }()

    /// The emoji the words find, by name or by meaning, best first; with
    /// none typed, the recent ones, then all.
    @MainActor
    static func find(_ words: String) -> [One] {
        let needles = words.lowercased().split(separator: " ").map(String.init)
        // Pinned, yours, then the ones most people reach for: what a
        // search puts first among what it finds.
        let pinned = self.pinned
        let recent = pinned + (self.recent + popular.filter { !self.recent.contains($0) }).filter { !pinned.contains($0) }
        let key = needles.joined(separator: " ") + "\t" + recent.joined()
        if let found, found.key == key { return found.list }
        let list: [One]
        if needles.isEmpty {
            let first = recent.compactMap { glyph in all.first { $0.glyph == glyph } }
            list = first + all.filter { !recent.contains($0.glyph) }
        } else {
            list = search(words, first: recent)
        }
        found = (key, list)
        return list
    }

    /// What the words find, by name or by meaning, best first, the ones in
    /// `first` a little ahead of their like: the field's Emoji place and a
    /// space's icon picker look the same way. No words find nothing.
    @MainActor
    static func search(_ words: String, first: [String] = []) -> [One] {
        let needles = words.lowercased().split(separator: " ").map(String.init)
        return needles.isEmpty ? [] : rank(needles, recent: first)
    }

    /// The emoji typed among the words, ":) 🚀 x" its 🚀: what a picker
    /// takes as picked rather than looked for. Digits and # are emoji only
    /// with the keycap after them, so plain ones are not.
    static func typed(in words: String) -> String? {
        words.first { char in
            guard let scalar = char.unicodeScalars.first, scalar.properties.isEmoji else { return false }
            return scalar.properties.isEmojiPresentation || char.unicodeScalars.count > 1
        }.map { one(for: String($0))?.glyph ?? String($0) }
    }

    /// The last words' emoji: the grid, its foot and ⌘K each ask.
    @MainActor static var found: (key: String, list: [One])?

    @MainActor static var recent: [String] {
        Store.settings.stringArray(forKey: "emoji.recent") ?? []
    }

    /// Kept at the head of the grid and of what words find, till unpinned.
    @MainActor static var pinned: [String] {
        Store.settings.stringArray(forKey: "emoji.pinned") ?? []
    }

    /// The ones most people reach for, filling Frequently Used until your
    /// own sixteen have.
    static let popular = ["👍", "❤️", "😂", "🔥", "🙏", "😊", "🎉", "✅", "👀", "😍", "🥲", "🤔", "👏", "💯", "🚀", "😅"]

    /// The grid, a part a heading: with no words, the pinned ones,
    /// Frequently Used (yours first, then the popular ones) and then every
    /// block; with words, what they find, the pinned and frequent first.
    @MainActor
    static func sections(_ words: String) -> [(title: String, list: [One])] {
        grid(words).sections
    }

    /// The grid as `sections` makes it and its emoji in one run. With no
    /// words it is every emoji there is, and the grid, its foot and the
    /// actions each ask for it many times a pass: made once for the pinned
    /// and recent ones it was made with.
    @MainActor
    static func grid(_ words: String) -> (sections: [(title: String, list: [One])], flat: [One]) {
        // Words are found again each time: what they find changes as the
        // meaning comes (`found`, which keeps their last answer).
        guard words.trimmingCharacters(in: .whitespaces).isEmpty else {
            let sections = made(words)
            return (sections, sections.first?.list ?? [])
        }
        let key = pinned.joined(separator: " ") + "\t" + recent.joined(separator: " ")
        if let shown, shown.key == key { return (shown.sections, shown.flat) }
        let sections = made(words)
        let flat = sections.flatMap(\.list)
        shown = (key, sections, flat)
        return (sections, flat)
    }

    /// The grid with no words, for the pinned and recent ones in its key.
    @MainActor static var shown: (key: String, sections: [(title: String, list: [One])], flat: [One])?

    /// Each part's emoji, in the order of `all`.
    static let bySection: [String: [One]] = Dictionary(grouping: all, by: \.section)

    /// Where each glyph first is in `all`.
    static let places: [String: Int] = {
        var out: [String: Int] = [:]
        for (index, one) in all.enumerated() where out[one.glyph] == nil { out[one.glyph] = index }
        return out
    }()

    @MainActor
    private static func made(_ words: String) -> [(title: String, list: [One])] {
        let pinned = self.pinned
        let frequent = (recent + popular.filter { !recent.contains($0) }).filter { !pinned.contains($0) }.prefix(16)
            .compactMap(one(for:))
        if words.trimmingCharacters(in: .whitespaces).isEmpty {
            let pins = pinned.compactMap(one(for:))
            var out: [(String, [One])] = pins.isEmpty ? [] : [("Pinned", pins)]
            out.append(("Frequently Used", frequent))
            for (section, _) in blocks {
                let list = bySection[section] ?? []
                if !list.isEmpty { out.append((section, list)) }
            }
            return out
        }
        let found = find(words)
        return found.isEmpty ? [] : [("Results", found)]
    }

    /// One by its glyph, with or without the variation selector.
    static func one(for glyph: String) -> One? {
        // The first of the three ways it can be written, as the search
        // through `all` finds it.
        var bare: String?
        if glyph.unicodeScalars.last == "\u{FE0F}" {
            bare = String(String.UnicodeScalarView(glyph.unicodeScalars.dropLast()))
        }
        let at = [places[glyph], places[glyph + "\u{FE0F}"], bare.flatMap { places[$0] }].compactMap { $0 }.min()
        return at.map { all[$0] }
    }

    @MainActor static func used(_ glyph: String) {
        var list = recent.filter { $0 != glyph }
        list.insert(glyph, at: 0)
        Store.settings.set(Array(list.prefix(16)), forKey: "emoji.recent")
    }

    /// Pinned at the end of the pinned ones, or unpinned.
    @MainActor static func pin(_ glyph: String) {
        let list = pinned
        Store.settings.set(list.contains(glyph) ? list.filter { $0 != glyph } : list + [glyph], forKey: "emoji.pinned")
    }

    /// Out of Frequently Used, as though it had never been picked.
    @MainActor static func forget(_ glyph: String) {
        Store.settings.set(recent.filter { $0 != glyph }, forKey: "emoji.recent")
    }

    /// Its code points as Unicode writes them: U+1F525, U+2764 U+FE0F.
    static func unicode(_ glyph: String) -> String {
        glyph.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }
}

// MARK: - the browser's side

extension Browser {
    /// The same destination and availability as its searchable field row.
    @discardableResult
    func openPlace(shortcut: Shortcut.Action) -> Bool {
        guard let place = FieldPlace.opened(by: shortcut), place.offered else { return false }
        openPlace(place)
        return true
    }

    @MainActor static var hintsWatch: AnyCancellable?

    /// The emoji words, while the field is Emoji's: in the place, or after a
    /// colon at the head of the field, ":fire", as chats have it.
    var emojiWords: String? {
        if query.place == .emoji { return typed }
        guard query.place == nil, query.scope == nil, typed.hasPrefix(":") else { return nil }
        let rest = typed.dropFirst()
        guard rest.allSatisfy({ $0.isLetter || $0 == " " }), !rest.hasPrefix(" ") else { return nil }
        return String(rest)
    }

    /// What the field is showing in its place, in order: the clips the words
    /// find, or the emoji.
    var placeClips: [Clips.Clip] { Clips.shared.find(typed, kind: query.clipFilter) }
    var placeEmoji: [Emoji.One] { emojiWords.map { Emoji.grid($0).flat } ?? [] }
    /// Emoji's grid, a part a heading (Emoji.sections).
    var emojiSections: [(title: String, list: [Emoji.One])] { emojiWords.map(Emoji.sections) ?? [] }

    /// What Clipboard History says with no clip to show, in its middle as
    /// the other places say it (PlaceEmpty): nothing copied yet, nothing of
    /// the kind chosen, or nothing the words find.
    var clipEmpty: PlaceEmpty? {
        guard query.place == .clipboard, placeClips.isEmpty else { return nil }
        let words = typed.trimmingCharacters(in: .whitespaces)
        let filter = query.clipFilter
        let all = FieldAction(id: "all", title: "Show All Types", symbol: Clips.Filter.all.symbol) { self.query.clipFilter = .all }
        if !words.isEmpty {
            return PlaceEmpty(place: .clipboard, searching: true,
                              title: filter == .all ? "Nothing for “\(words)”" : "Nothing for “\(words)” in \(filter.rawValue)",
                              detail: "Clips are found by what they say, the page they came from and the app they were copied in.",
                              actions: filter == .all ? [] : [all])
        }
        if filter != .all, !Clips.shared.items.isEmpty {
            let title: String
            switch filter {
            case .text: title = "No text copied"
            case .links: title = "No links copied"
            case .images: title = "No images copied"
            case .colors: title = "No colors copied"
            case .files: title = "No files copied"
            case .fast, .all: title = "Nothing copied in Yab"
            }
            return PlaceEmpty(place: .clipboard, searching: true, title: title, detail: "", actions: [all])
        }
        return PlaceEmpty(place: .clipboard, searching: false, title: "Nothing copied yet",
                          detail: "What you copy in any app while Yab is open comes here for a month, or for good once pinned, and goes back with Return. Passwords and private tabs are left out.")
    }

    /// What Emoji says when the words find none, once it has looked by
    /// meaning too (Emoji.settled); until then it holds one slot instead.
    var emojiEmpty: PlaceEmpty? {
        guard let words = emojiWords?.trimmingCharacters(in: .whitespaces), !words.isEmpty,
              emojiSections.isEmpty, Emoji.settled else { return nil }
        return PlaceEmpty(place: .emoji, searching: true, title: "Nothing for “\(words)”",
                          detail: "Emoji are found by their name and by what they mean: try a feeling or a thing.")
    }

    /// ↑ and ↓ in Emoji's grid: a row up or down, the column kept, across
    /// from one part to the next where a part ends mid-row.
    func walkEmoji(_ rows: Int) -> Bool {
        let parts = emojiSections.map(\.list.count)
        guard parts.reduce(0, +) > 0 else { return true }
        let columns = Omnibox.emojiColumns
        var part = 0, at = query.spot
        while part < parts.count, at >= parts[part] { at -= parts[part]; part += 1 }
        guard part < parts.count else { query.spot = 0; return true }
        let column = at % columns
        if rows > 0 {
            if at + columns < parts[part] {
                at += columns
            } else if (at / columns) < (parts[part] - 1) / columns {
                at = parts[part] - 1
            } else if part + 1 < parts.count {
                part += 1
                at = min(column, parts[part] - 1)
            }
        } else {
            if at - columns >= 0 {
                at -= columns
            } else if part > 0 {
                part -= 1
                let last = (parts[part] - 1) / columns * columns
                at = min(last + column, parts[part] - 1)
            }
        }
        query.spot = parts.prefix(part).reduce(0, +) + at
        return true
    }

    /// Tab, or a place's row: the field becomes that place's.
    func enterPlace(_ place: FieldPlace, filter: Int = 0, remember: Bool = true) {
        let fromField = remember && fresh
        if place != .selection { endAnswer() }
        if query.place == .files && place != .files {
            cancelFileAnswer()
            fileSelected.removeAll()
        }
        dropScope()
        query.acting = nil
        // Set the destination's category before typed's setter can ask for
        // rows, and before stockPlace starts its initial asynchronous read.
        query.placeFilter = filter
        query.place = place
        query.placeFromField = fromField
        query.spot = 0
        picked = nil
        query.pointed = nil
        typed = ""
        stockPlace(place)
        query.focusRequest += 1
    }

    /// Tab on a place's name.
    func enterNamedPlace() -> Bool {
        guard query.place == nil, query.scope == nil, let place = FieldPlace.named(typed) else { return false }
        // A site whose name the words begin as well is the site's to take,
        // unless the words are all of the place's own name.
        if query.offering != nil, !place.names.contains(typed.trimmingCharacters(in: .whitespaces).lowercased()) { return false }
        enterPlace(place)
        return true
    }

    /// The empty field's row for Yab on a phone is chosen, and its code stands
    /// beside the list.
    var phoneRowChosen: Bool {
        query.typed.isEmpty && query.place == nil
            && (query.current.map { query.offers.indices.contains($0) && PhoneBeta.offered(query.offers[$0]) } ?? false)
    }

    /// ← or → on that row: the code on that side of the switch, as the arrows
    /// have nothing else to do in an empty field. True when taken.
    func showPhone(_ phone: YabPhone) -> Bool {
        guard !prefs.compactField, phoneRowChosen else { return false }
        if PhoneBetaState.shared.phone != phone { PhoneBetaState.shared.turn() }
        return true
    }

    /// ⌫ or Escape returns to the plain field once nested steps are gone.
    @discardableResult
    func leavePlace() -> Bool {
        query.returnPlace = nil
        if query.place == .files { dropFiles(); return true }
        if mailStepBack() { return true }
        if query.acting != nil {
            query.acting = nil
            return true
        }
        // A command's answer: one being written stops, keeping its words;
        // one written goes, and the selection's commands are the rows again.
        if query.answering {
            if selectionCommands.stage == .running {
                selectionCommands.stop()
                return true
            }
            // A question asked from the words (nothing was selected): the
            // words again, and their rows, to search them instead.
            let asked = fieldSelection?.text.isEmpty == true ? selectionCommands.command?.prompt : nil
            query.answering = false
            selectionCommands.close()
            query.spot = 0
            if let asked {
                fieldSelection = nil
                query.place = nil
                replaceTyped(asked)
                return true
            }
            replaceTyped("")
            return true
        }
        // Writing, then bringing in: back to the list first.
        if query.edit != nil {
            cancelEdit()
            return true
        }
        if leaveMore() { return true }
        if upFolder() { return true }
        if query.place == nil, query.settingUp {
            query.settingUp = false
            typed = ""
            return true
        }
        if query.place == nil, emojiWords != nil {
            typed = ""
            return true
        }
        guard query.place != nil else { return false }
        // Out of the selection's place: the field over the page, its address
        // back, the selection's commands still its first rows.
        if query.place == .selection, let here = query.here, active?.address == here {
            endAnswer()
            query.place = nil
            query.spot = 0
            typed = Address.whole(here)
            return true
        }
        query.place = nil
        query.revealed = nil
        query.shown = [:]
        query.edit = nil
        query.stock = PlaceStock()
        query.spot = 0
        typed = ""
        // Over a page, a place is opened the way ⌘L is, for its rows to go
        // there; out of it, the page's address is long gone, and an emptied
        // ⌘L is a field asking nothing. What it is now is ⌘T's.
        if !fresh, query.form == nil, active?.isBlank == false { openFresh() }
        return true
    }

    /// The arrows, in a place: one row, or in the emoji's grid, a row of it.
    func walkPlace(_ step: Int) -> Bool {
        // The selection's commands are the field's own rows: walked as those.
        if query.place == .selection, emojiWords == nil { return false }
        let count: Int
        if emojiWords != nil { count = placeEmoji.count } else if query.place == .clipboard { count = placeClips.count } else if let place = query.place, place != .mail {
            if let empty = placeEmpty { count = empty.sources.count } else { count = placeItems.count }
            // Writing a row: the arrows stay in its fields.
            if query.edit != nil { return true }
        } else { return false }
        guard count > 0 else { return true }
        // A plain arrow puts the picks down, as a click does.
        query.unpick()
        // Round from the foot to the top and back, as the field's rows go,
        // but not across Emoji's grid, nor in History while it has older
        // pages still to bring in: its last row isn't the end yet.
        let more = query.place == .history && !query.stock.ended
        if emojiWords == nil, !more, walksRound {
            query.spot = ((query.spot + step) % count + count) % count
        } else {
            query.spot = max(0, min(count - 1, query.spot + step))
        }
        return true
    }

    /// Where something picked in the field goes on the page: into the box
    /// the caret was in when the field came up, or, with none, the clipboard.
    var pastesIntoPage: Bool { query.pageTyping && active?.isBlank == false }

    // MARK: rows of the field's own

    /// Under the empty field: what can be done to the page ⌘L raised it
    /// over, or what was just copied, for ⌘T.
    func quietRows() -> [Suggestion] {
        if untouched != nil, let tab = fieldPage {
            // Now, two at most over a page, and nothing in a private tab: a
            // meeting within ten minutes, a link just copied, then what an
            // agent can do here, which teaches ⌘J by showing it.
            var now: [Suggestion] = []
            let action = Hints.shared.actions(on: tab).first
            var acted = false
            if !tab.shy {
                Hints.shared.compose()
                let clock = Hints.now
                for hint in Hints.overPage(Hints.shared.queue, now: clock) {
                    var row = Suggestion(key: hint.title, title: "", url: nil, kind: .hint(hint.id))
                    row.handed = Hints.shared.handedWords(hint.id)
                    now.append(row)
                }
                if now.count < 2, let action, Shell.cached.map({ $0.claude != nil || $0.codex != nil }) == true {
                    now.append(Suggestion(key: action.title, title: tab.label, url: nil, kind: .page("agent-now")))
                    acted = true
                }
            }
            var base = FieldPageRows.base(in: pageRowSettings).map { row -> Suggestion in
                let title: String
                switch row {
                case .copy: title = Address.pretty(Diary.shareable(tab.address ?? URL(fileURLWithPath: "/")))
                case .markdown: title = "[\(tab.label)]"
                case .duplicate: title = ""
                }
                return Suggestion(key: row.title, title: title, url: nil, kind: .page(row.rawValue))
            }
            if let action, !acted {
                let at = base.firstIndex { $0.kind == .page(FieldPageRows.Base.duplicate.rawValue) } ?? base.endIndex
                base.insert(Suggestion(key: action.title, title: "Agent", url: nil, kind: .page("agent")), at: at)
            }
            var rows = now + base
            rows += pageRows(on: tab)
            // ⌘L is the address and the page. What can be done to text
            // selected on it is ⌘J's, never here.
            return rows
        }
        guard askingNew else { return [] }
        // The compact private field keeps its existing short list. A
        // private tab in a normal window keeps its empty field. The large
        // field in a private window uses the usual Favorites, Recent Tabs,
        // Frequent and Quick Actions below; its visits still are not saved.
        if privateBrowsing && (prefs.compactField || windowPurpose != .privateOnly) {
            guard windowPurpose == .privateOnly else { return [] }
            var seen = Set<URL>()
            return tabs.filter { $0.id != activeID && !$0.isBlank && $0.address != nil }
                .sorted { $0.touched > $1.touched }
                .filter { tab in tab.address.map { seen.insert($0).inserted } ?? false }
                .prefix(prefs.compactField ? Omnibox.compactRows : 5)
                .compactMap { tab in tab.address.map { Suggestion(key: tab.label, title: Tab.place($0), url: $0, kind: .open, tab: tab.id) } }
        }
        // The compact card's ⌘T, as Arc's: the tabs looked at last, the one
        // in front left out, each to switch to, and one row of Now on top
        // when something there can't wait.
        if prefs.compactField, asked != .split {
            var rows: [Suggestion] = []
            let sections = FieldSections.shared
            if sections.isOn(.now), let hint = Hints.overPage(nowHints(), now: Hints.now).first {
                var row = Suggestion(key: hint.title, title: "", url: nil, kind: .hint(hint.id))
                row.handed = Hints.shared.handedWords(hint.id)
                rows.append(row)
            }
            guard sections.isOn(.recent) else { return rows }
            var seen: [ObjectIdentifier: Set<URL>] = [:]
            let recent = tabs.filter { $0.id != activeID && !$0.isBlank && $0.address != nil && !$0.bench }
                .sorted { $0.touched > $1.touched }
                .filter { tab in
                    guard let url = tab.address else { return false }
                    return seen[ObjectIdentifier(tab.store), default: []].insert(url).inserted
                }
                .prefix(Omnibox.compactRows - rows.count)
            for tab in recent {
                guard let url = tab.address else { continue }
                rows.append(Suggestion(key: tab.label, title: Tab.place(url), url: url, kind: .open, tab: tab.id))
            }
            return rows
        }
        // Eight rows at most, in one order: what can't wait, your
        // favorites, the tabs you have open, the sites you go to, the
        // app's own actions, and getting started last. Only favorites go
        // past the eight, all listed, the box
        // scrolling to them; Recent Tabs, Frequent and Quick Actions then
        // have no room, and getting started is still the last row.
        let now = Hints.now
        // What yab notices is worked out again as the field opens: a link
        // copied a second ago is there, one copied long ago is gone.
        Hints.shared.compose()
        for hint in Hints.shared.rows where hint.done == true {
            DispatchQueue.main.async { Hints.shared.settle(hint.id) }
        }
        let live = Hints.shared.rows.filter { $0.done != true }
        // Getting started, all of it one row; taken, its rows are the list.
        let setup = Hints.shared.queue.filter { $0.setup && $0.done != true }
        if query.settingUp, !setup.isEmpty {
            return setup.map { Suggestion(key: $0.title, title: HintList.detail($0, now: now), url: nil, kind: .hint($0.id)) }
        }
        // Yab for your phone is a row of its own under the heading, its code
        // beside the list (PhoneBeta); the other steps stay one row.
        // Connect Claude or ChatGPT is one beside it (AIUse.connectOffered).
        let phone = setup.first { $0.id == PhoneBeta.hintID }
        let connect = setup.first { $0.id == Hints.connectID }
        let steps = setup.filter { $0.id != PhoneBeta.hintID && $0.id != Hints.connectID }
        // The parts, as Settings › Search has them: Split View's field is
        // only ever the tabs that can go beside the page.
        let chosen = FieldSections.shared
        let off = asked == .split ? [] : chosen.off
        let order = asked == .split ? FieldSection.allCases : chosen.order
        var parts: [FieldSection: [Suggestion]] = [:]
        // Text selected on the page ⌘T came up over: what can be done to
        // it first, four at most, the commands ⌘J would list, in its order.
        var rows: [Suggestion] = selectionRows(limit: 4)
        // ⌘T over an article with no address bar, where no book stands in
        // sight: reading mode first, the way to it beside ⌥⌘R.
        if !off.contains(.reading), asked == .tab, !barShown, let tab = active, ReadingDoor.offered(tab) {
            parts[.reading] = [Suggestion(key: Command.reader.title(in: self), title: Command.reader.keys, url: nil, kind: .command(.reader))]
        }
        var nowRows: [Suggestion] = []
        if !off.contains(.now), asked != .split, let mail = mailNowRow(now: now) { nowRows.append(mail) }
        if !off.contains(.now) {
            // Yab Wrapped, its row at the top of Now while a moment is due and
            // not yet played: the first 100 days, a December's year (Wrapped.swift).
            Wrapped.shared.refresh()
            let wrapped = Wrapped.shared.due
            if let wrapped { nowRows.append(Suggestion(key: "Yab Wrapped", title: wrapped.title, url: nil, kind: .page("wrapped"))) }
            // Now: only what has a time, two at most with Wrapped among them.
            // More than that: Show All, its row saying how many more, opens
            // all of Now as a place. Nothing: no Now at all.
            let timed = nowHints()
            let nowRoom = wrapped == nil ? 2 : 1
            // A promise stands only as the budget lets it (Promises.mayStand):
            // one at most beside the rest, two different ones a day, none left
            // untouched three days. One passed over is first under Show All.
            let standing = nowStanding(timed, room: nowRoom, now: now)
            for hint in standing {
                // The title and where it stands (Omnibox), the rest in the preview.
                var row = Suggestion(key: hint.title, title: "", url: nil, kind: .hint(hint.id))
                row.handed = Hints.shared.handedWords(hint.id)
                nowRows.append(row)
            }
            if timed.count > standing.count {
                nowRows.append(Suggestion(key: "Show All in Now", title: "\(timed.count - standing.count)", url: nil, kind: .place(.now)))
            }
        }
        // Favorites, in your order, right under Now, the top row
        // (FieldFavorites). All of them: the parts after
        // share what is left of the eight, none past it, and with no
        // favorites nothing moves.
        let favored = off.contains(.favorites) ? [] : favoriteRows(now: now)
        let pages = favored.filter { $0.kind == .open || $0.kind == .visited }
        let kept = Set(pages.compactMap { $0.url.map(FieldFavorite.page) })
        // A download going or just done is the one place that says itself,
        // on Downloads' own row when that is a favorite.
        if !off.contains(.now), rows.count + (parts[.reading]?.count ?? 0) + nowRows.count < 2,
           !favored.contains(where: { $0.kind == .place(.downloads) }), let detail = downloadNews(now: now) {
            nowRows.append(Suggestion(key: FieldPlace.downloads.title, title: detail, url: nil, kind: .place(.downloads)))
        }
        parts[.now] = nowRows
        parts[.favorites] = favored
        // Recent Tabs: the ones looked at last, besides the one in front.
        // An agent's tabs are its task's, in its folder, not yours to go back to.
        // Split View's field lists only the ones that can go beside the page.
        // A favorite's page is its row up there; a private tab on it is
        // somewhere else, which that row never takes you.
        var recentURLs: [ObjectIdentifier: Set<URL>] = [:]
        let recent = off.contains(.recent) ? [] : tabs.filter { $0.id != activeID && !$0.isBlank && $0.address != nil && !$0.bench }
            .filter { asked != .split || splitTakes($0) }
            .filter { tab in tab.shy || tab.address.map { !kept.contains(FieldFavorite.page($0)) } ?? false }
            .sorted { $0.touched > $1.touched }
            // One row per page, keeping the last tab used. Separate sign-ins
            // and complete URLs still name separate destinations.
            .filter { tab in
                guard let url = tab.address else { return false }
                return recentURLs[ObjectIdentifier(tab.store), default: []].insert(url).inserted
            }
        // Just made by hand what an action makes: its alias, said once
        // or twice where the next one would be asked for, then never.
        // A favorite one is listed up there instead, and not hinted.
        let favorite = { (action: QuickAction) in favored.contains { $0.kind == .quickAction(action.id) } }
        let hinting = off.contains(.actions) ? nil : QuickActions.shared.hinting(now: now).flatMap { favorite($0) ? nil : $0 }
        let enabled = off.contains(.actions) ? [] : QuickActions.shared.actions.filter { $0.enabled && !favorite($0) }
        let actions = ((hinting.map { [$0] } ?? []) + enabled.filter { $0.id != hinting?.id }).compactMap { action in
            action.destination.map {
                Suggestion(key: action.name, title: action.id == hinting?.id ? "Next time, type \(action.alias)" : action.host,
                           url: $0, kind: .quickAction(action.id))
            }
        }
        // Frequent: the sites you go to, each by its page, that no open tab
        // or favorite is on; the habit of this hour first, said in two words.
        // With Frequent kept to the space, a habit of another space's is not
        // listed either.
        var frequent: [Suggestion] = []
        if !off.contains(.frequent) {
            var hosts = Set(tabs.compactMap { $0.address.flatMap { Browser.site($0.host() ?? "") } })
            let sites = Set(pages.compactMap { $0.url.map { Browser.site($0.host() ?? "") } })
            hosts.formUnion(sites)
            let space = frequentSpace
            if let habit = live.first(where: { $0.source == .habit }),
               habit.url?.host().map({ !sites.contains(Browser.site($0)) }) ?? true,
               space.map({ space in habit.url.map { history.been(at: $0, in: space) } ?? false }) ?? true {
                frequent.append(Suggestion(key: habit.title, title: "Usually now", url: nil, kind: .hint(habit.id)))
                if let host = habit.url?.host() { hosts.insert(Browser.site(host)) }
            }
            for trace in history.frequent(8, now: now, space: space) {
                guard hosts.insert(Browser.site(trace.url.host() ?? "")).inserted else { continue }
                frequent.append(Suggestion(key: trace.title, title: Address.pretty(trace.url), url: trace.url, kind: .visited, frequent: trace.key))
            }
        }
        // Getting started's rows keep their room: Yab for iPhone, Connect
        // Claude or ChatGPT and Set up Yab each take one of the eight.
        let taken = rows.count + (parts[.reading]?.count ?? 0) + nowRows.count + favored.count
        let left = 8 - taken - (phone == nil ? 0 : 1) - (connect == nil ? 0 : 1) - (steps.isEmpty ? 0 : 1)
        let shares = FieldSections.shares(left: left, have: [.recent: recent.count, .actions: actions.count, .frequent: frequent.count],
                                          order: order, off: off)
        parts[.recent] = recent.prefix(shares[.recent] ?? 0).compactMap { tab in
            tab.address.map { Suggestion(key: tab.label, title: Tab.place($0), url: $0, kind: .open, tab: tab.id) }
        }
        let shownActions = Array(actions.prefix(shares[.actions] ?? 0))
        if let hinting, shownActions.contains(where: { $0.kind == .quickAction(hinting.id) }) {
            DispatchQueue.main.async { QuickActions.shared.showedHint(hinting.id) }
        }
        parts[.actions] = shownActions
        parts[.frequent] = Array(frequent.prefix(shares[.frequent] ?? 0))
        for section in order { rows += parts[section] ?? [] }
        if let phone {
            rows.append(Suggestion(key: phone.title, title: HintList.detail(phone, now: now), url: nil, kind: .hint(phone.id)))
        }
        if let connect {
            rows.append(Suggestion(key: connect.title, title: HintList.detail(connect, now: now), url: nil, kind: .hint(connect.id)))
        }
        if !steps.isEmpty {
            rows.append(Suggestion(key: "Set up Yab", title: "\(steps.count) left", url: nil, kind: .page("setup")))
        }
        return rows
    }

    /// Downloads' news for the empty field: files coming in, or one that
    /// arrived in the last ten minutes. Nil when there is none.
    func downloadNews(now: Date) -> String? {
        DownloadNews.detail(now: now, started: hoard.fetches.filter { !$0.failed }.map(\.started), kept: loot.kept)
    }

    /// The commands for the text selected on the page under the field, as
    /// rows: the best `limit` of them, or those the words name.
    func selectionRows(limit: Int, naming words: String = "") -> [Suggestion] {
        guard let snap = fieldSelection else { return [] }
        // In ⌘J's place, anything selected; over ⌘T's field, text selected
        // on the page it came up over (Browser.openFresh); never ⌘L's.
        if query.place == .selection {
            guard !fresh || !snap.text.isEmpty else { return [] }
        } else {
            guard asked == .tab, active?.isBlank == false, !snap.text.isEmpty else { return [] }
        }
        var commands = selectionCommands.offered(for: snap, actions: []).filter { !$0.id.hasPrefix("skill-") }
        let q = words.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { commands = SelectionCommands.matching(q, in: commands) }
        var rows = commands.prefix(limit).map { command in
            // Title Case, as the field's other things to do are written.
            Suggestion(key: SelectionCommand.menuTitle(command.name), title: selectionSource(command, snap: snap), url: nil, kind: .page("sel:" + command.id))
        }
        // In ⌘J's place, words that name no command are a question for the
        // agent: the last row, and the first when nothing else is left.
        // Nothing typed: last, the task line, to hand the agent a task
        // about the selection in words of your own.
        // Not from a private tab: a task is given nothing of one, so there
        // would be nothing of this selection to ask about (TaskLine.open).
        let shy = privateBrowsing
        if query.place == .selection, q.isEmpty, !shy, AIUse.offers {
            rows.append(Suggestion(key: "Ask About This\u{2026}", title: "", url: nil, kind: .page("sel-task")))
        }
        if query.place == .selection, !q.isEmpty, Agents.ready {
            let ask = SelectionCommand(id: "ask", name: "Ask", prompt: q, executor: "agent", custom: true)
            rows.append(Suggestion(key: "Ask \(AgentSetupModel.name(selectionCommands.agent(for: ask).cli)) \u{201C}\(q)\u{201D}",
                                   // Its name says who already, unless there is none; from a
                                   // private tab, that the words leave this Mac.
                                   title: selectionCommands.runner(ask, for: snap) == nil ? "Connect an agent" : shy ? "leaves this Mac" : "",
                                   url: nil, kind: .page("sel-ask:" + q)))
        }
        return Array(rows)
    }

    /// Where a selection command would run, as its row in ⌘J's list says,
    /// and, from a private tab, that the text leaves this Mac, as the
    /// commands' own list says it (SelectionList.source).
    private func selectionSource(_ command: SelectionCommand, snap: SelectionSnapshot) -> String {
        switch selectionCommands.runner(command, for: snap) {
        case nil: return "Connect an agent"
        case "mac": return "on this Mac"
        case let cli? where AgentPlan.isPlan(cli): return selectionCommands.agentTitle(command) + (privateBrowsing ? " · leaves this Mac" : "")
        default: return ""
        }
    }

    /// A row whose Return sets something going rather than opening it: a
    /// hint with nowhere to go, getting started's.
    func startsWork(_ offer: Suggestion) -> Bool {
        guard case .hint(let id) = offer.kind else { return false }
        return Hints.shared.row(id)?.url == nil
    }

    /// Which part of the empty field's list a row is in, for its heading.
    func quietSection(_ offer: Suggestion) -> String? {
        // In the selection's own place its name is at the foot, once.
        if query.place == .selection { return nil }
        if let heading = offer.pageHeading { return heading }
        if offer.favorite { return "Favorites" }
        if case .page(let what) = offer.kind, what.hasPrefix("mail:") { return Browser.mailRows[String(what.dropFirst(5))]?.section }
        switch offer.kind {
        case .page(let what) where what.hasPrefix("sel:"): return "Selection"
        case .hint(let id):
            let hint = Hints.shared.row(id)
            if hint?.setup == true { return "Set up Yab" }
            return hint?.source == .habit ? "Frequent" : "Now"
        case .clip, .page("agent-now"), .page("wrapped"), .page("mail-now"), .place: return "Now"
        case .open: return "Recent Tabs"
        case .visited: return "Frequent"
        case .quickAction: return "Quick Actions"
        // Its own name says what it is: no heading over the one row.
        case .page("setup"): return nil
        case .page: return "This Page"
        default: return nil
        }
    }

    /// Hints come and go while the field is up: its empty list follows.
    func followHints() {
        guard Browser.hintsWatch == nil else { return }
        Browser.hintsWatch = Hints.shared.$rows.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            // Not under a hand walking the list: the rows would move under it.
            guard let self, self.fieldShowing, self.askingNew, self.typed.isEmpty, self.query.place == nil,
                  self.picked == nil, self.query.pointed == nil else { return }
            self.typed = ""
            Hints.shared.saw()
        }
    }

    /// Rows the words make besides places: a sum, a place of the field's
    /// own, and the one clip they find best.
    func ownRows(for text: String, address: Bool) -> (sum: Suggestion?, rest: [Suggestion]) {
        var sum: Suggestion?
        if let answer = Calc.answer(text) {
            sum = Suggestion(key: answer.copy, title: text, url: nil, kind: .sum)
            // Rates coming in while the words still ask for them: asked again.
            Rates.shared.came = { [weak self] in
                guard let self, self.fieldShowing, Calc.answer(self.typed) != nil else { return }
                self.typed = self.typed
            }
        }
        var rest: [Suggestion] = []
        guard !address else { return (sum, rest) }
        if let place = FieldPlace.named(text) {
            rest.append(Suggestion(key: place.title, title: placeDetail(place), url: nil, kind: .place(place)))
        }
        if text.count >= 3, !privateBrowsing, let clip = Clips.shared.first(text),
           // A link the history already offers is that row, not a second one.
           !(clip.kind == .link && history.suggestions(for: text, limit: 5).contains { $0.url.map(Address.pretty) == URL(string: clip.text).map(Address.pretty) }) {
            rest.append(Suggestion(key: clip.title, title: [clip.app, clip.page?.host()].compactMap { $0 }.joined(separator: " · "),
                                   url: nil, kind: .clip(clip.id)))
        }
        return (sum, rest)
    }

    // MARK: doing

    /// A row of the field's own, taken.
    func takeOwn(_ offer: Suggestion) -> Bool {
        switch offer.kind {
        case .sum:
            let value = offer.key
            close()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            return true
        case .place(let place):
            enterPlace(place)
            return true
        case .within(let place):
            // The place, searching the words already typed.
            let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            enterPlace(place)
            typed = words
            if place == .history { askHistory() }
            return true
        case .command(let command):
            // The Actions list is a field entry too; a command run by its
            // menu or shortcut still uses openPlace's direct route.
            let place: FieldPlace
            switch command {
            case .history: place = .history
            case .downloads: place = .downloads
            case .bookmarks: place = .bookmarks
            case .passwords: place = .passwords
            case .autofill: place = .autofill
            case .boostStore: place = .store
            default: return false
            }
            if command.available(in: self) { enterPlace(place) }
            return true
        case .clip(let id):
            guard let clip = Clips.shared.items.first(where: { $0.id == id }) else { return true }
            // Just copied and a link: it is somewhere to go.
            if clip.kind == .link, let url = URL(string: clip.text), query.place == nil, typed.isEmpty {
                let asking = self.asking
                close()
                place(url, asking, from: active)
                return true
            }
            paste(clip)
            return true
        case .hint(let id):
            guard let hint = Hints.shared.row(id) else { return true }
            // Handed to the agent: its chat, where it asks and answers.
            if let session = Browser.handedChat(id) {
                close()
                showChat(session.id)
                // Its answer opened: the row's work is over (Hints.handedLook).
                if session.state == .done { Hints.shared.opened(session.id, by: "row") }
                return true
            }
            // A meeting in its last minutes: Join, as its row offered.
            if HintList.joining(hint, now: Hints.now), let join = hint.join {
                // In the empty tab that asked; over a page, in a tab of its
                // own, the page left be; the call's own tab if it is open.
                let asking = !fresh && active?.isBlank == true ? nil : self.asking ?? .tab
                close()
                if openCall(join) { return true }
                place(join, asking, from: nil)
                return true
            }
            if hint.url == nil { close() }
            Hints.shared.take(hint, in: self)
            return true
        case .task:
            let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            close()
            // In tabs of its own, worked in the chat column.
            if Agents.ready {
                if let session = Agents.shared.task(words, context: [], on: nil) { showChat(session.id) }
            } else { TaskLine.connect() }
            return true
        case .ask:
            askInField(typed.trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        case .request(let index):
            runRequest(index)
            return true
        case .page("sel-task"):
            let snap = fieldSelection
            close()
            if let tab = active { TaskLine.shared.open(on: tab, selection: snap?.text) }
            return true
        case .page(let what) where what.hasPrefix("mail:"):
            takeMail(String(what.dropFirst(5)))
            return true
        case .mailAccount(let account):
            close()
            showMail(account: account)
            return true
        case .page(let what) where what.hasPrefix("sel-ask:"):
            // Words of your own about the selection, to your agent, answered
            // in the field (FieldAnswer).
            let words = String(what.dropFirst(8))
            if let tab = active, let snap = fieldSelection {
                answer(SelectionCommand(id: "ask", name: "Ask", prompt: words, executor: "agent", custom: true), on: tab, snapshot: snap)
            }
            return true
        case .page(let what) where what.hasPrefix("sel:"):
            // The command runs on the selection and answers in the field;
            // what it writes goes into the page
            // from there (Replace Selection) or is copied.
            let id = String(what.dropFirst(4))
            guard let tab = active, let snap = fieldSelection else { return true }
            selectionCommands.load()
            guard let command = selectionCommands.commands.first(where: { $0.id == id && $0.enabled }) else { return true }
            // What needs no model (a map, a call, a date, a quote) does its
            // thing at once, as before: the field goes.
            if selectionCommands.runner(command, for: snap) == "local" {
                close()
                selectionCommands.run(command, on: tab, snapshot: snap)
            } else {
                // From ⌘T's list: answered in the selection's place, as
                // from ⌘J's, so the answer and Back are that place's.
                if query.place != .selection { enterPlace(.selection) }
                answer(command, on: tab, snapshot: snap)
            }
            return true
        case .page(let what) where what.hasPrefix("menu:"):
            let id = String(what.dropFirst(5))
            close()
            _ = MenuCommands.runTarget(id, in: self)
            return true
        case .page(let what) where what.hasPrefix("ext:"):
            // An extension's command, by its alias or name.
            close()
            takeExtensionCommandRow(what)
            return true
        case .page(let what) where what.hasPrefix("us:") || what.hasPrefix("us-off:"):
            // A userscript's menu command on the page in front, or the
            // script turned off (docs/userscripts.md, "Commands in ⌘T").
            close()
            takeUserscriptRow(what)
            return true
        case .page("wrapped"):
            close()
            Wrapped.shared.show(in: self)
            return true
        case .page("mail-now"):
            takeMailNow()
            return true
        case .page("setup"):
            // Getting started's rows, in the list's place; Escape goes back.
            query.settingUp = true
            typed = ""
            return true
        case .page(let what) where FieldPageRows.command(what) != nil:
            let page = fieldPage
            close()
            if let command = FieldPageRows.command(what) { takePageAction(command, on: page) }
            return true
        case .page("tracking"):
            let url = fieldPage?.address
            close()
            if let url {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                toaster.pop(feedback: .success)
            }
            return true
        case .page(let what):
            // Closing the field releases its guest. Keep the page that
            // supplied these rows, even when the browser has no active tab.
            let page = fieldPage
            let guest = fieldGuest
            close()
            switch what {
            case "copy":
                if let guest { LinkWindow.all.first { $0.tab === guest }?.copyPage() }
                else { copyAddress(page) }
            case "markdown":
                if let guest { LinkWindow.all.first { $0.tab === guest }?.copyPage(markdown: true) }
                else { copyMarkdownLink() }
            case "duplicate": duplicate(page)
            case "reader": toggleReader(page)
            default: if let page, let action = Hints.shared.actions(on: page).first { Agents.shared.act(action, on: page) }
            }
            return true
        default:
            return false
        }
    }

    /// A place's row's words beside its name: how much it holds.
    func placeDetail(_ place: FieldPlace) -> String {
        switch place {
        case .clipboard: return Clips.shared.items.isEmpty ? "" : "\(Clips.shared.items.count) copied"
        case .emoji: return "or type a colon"
        case .downloads:
            let going = hoard.fetches.filter { !$0.failed }.count
            if going > 0 { return "\(going) downloading" }
            return loot.kept.isEmpty ? "" : "\(loot.kept.count) file\(loot.kept.count == 1 ? "" : "s")"
        case .passwords:
            guard let host = active?.address?.host(), !host.isEmpty else { return "" }
            return "for \(Browser.site(host)) and every site"
        case .autofill: return ""
        case .history: return "search what you have visited"
        case .bookmarks:
            let count = bookmarks.count
            return count == 0 ? "" : "\(count.formatted()) kept"
        case .chats:
            let working = Chats.shared.all.filter { Agents.shared.session($0.id)?.state.live == true }.count
            if working > 0 { return "\(working) working" }
            let count = Chats.shared.all.count
            return count == 0 ? "" : "\(count) kept"
        case .routines:
            let routines = Routines.shared.all
            let running = routines.filter { Agents.shared.session($0.session)?.state.live == true }.count
            if running > 0 { return "\(running) running" }
            let fresh = routines.filter { $0.chat.flatMap { Chats.shared.chat($0) }?.unread == true }.count
            if fresh > 0 { return "\(fresh) with something new" }
            return routines.isEmpty ? "" : "\(routines.count) set"
        case .snippets:
            let count = MailSnippets.shared.all.count
            return count == 0 ? "" : count == 1 ? "1 kept" : "\(count) kept"
        case .files: return "choose a file for this page"
        case .selection: return ""
        case .mail: return "search mail and act on it"
        case .store:
            let here = StoreCatalog.shared.on(active?.address?.host()).count
            if here > 0, let host = active?.address?.host() { return "\(here) for \(StoreCatalog.bare(host))" }
            return "change how sites look and work"
        case .now:
            let count = nowHints().count
            return count == 0 ? "" : count == 1 ? "1 thing" : "\(count) things"
        case .purchases:
            let book = Purchases.shared
            if let total = book.monthlySaid { return total + " in subscriptions" }
            return book.orders.isEmpty ? "subscriptions, orders and receipts" : "\(book.orders.count) on the way"
        }
    }

    /// Whether a Now row is of the kind its filter is on, in the order
    /// FieldPlace.now's filters list them: Settings' kinds of yab's own rows
    /// (Noticing.Kind), and an agent's finds under Agents.
    static func nowKind(_ hint: Hint, _ filter: Int) -> Bool {
        let kind = Noticing.Kind.of(hint)
        switch filter {
        case 1: return kind?.isPromise == true
        case 2: return kind?.isMail == true
        case 3: return kind == .meeting
        case 4: return kind == .task || kind == .wake || (kind == nil && hint.source != .noticed)
        case 5: return kind == .copied
        case 6: return kind == .phone
        default: return true
        }
    }

    /// The Now rows that stand in the field's room, the promises among
    /// them counted as having stood today (the budget's memory).
    func nowStanding(_ timed: [Hint], room: Int, now: Date) -> [Hint] {
        let standing = Hints.top(timed, room: room, may: Promises.shared.mayStand(now: now))
        Promises.shared.stood(standing.filter(Hints.promise).map(\.id), now: now)
        return standing
    }

    /// What Now holds: what has a time, all of it, past the four the
    /// queue's rows keep (Hints.compose).
    func nowHints() -> [Hint] {
        Hints.shared.queue.filter { $0.done != true && !$0.setup && $0.source != .habit }
    }

    /// A Now row's actions, the same in Now's place as under the plain field.
    func hintActions(_ id: String) -> [FieldAction] {
        guard let hint = Hints.shared.row(id) else { return [] }
        return plainActions(Suggestion(key: hint.title, title: "", url: nil, kind: .hint(id)))
    }

    /// A command's answer in the field, gone with the place it was in: its
    /// agent stopped. One being put into the page has already left the
    /// field (SelectionCommands.handOver) and goes on.
    func endAnswer() {
        guard query.answering else { return }
        query.answering = false
        query.choosingModel = false
        if selectionCommands.answering { selectionCommands.close() }
    }

    /// Keep the destination when a pick or a click puts the field away.
    func rememberPlace() {
        // Selection and Files are requests from a specific page, not
        // standalone destinations. Their old request must never be replayed.
        guard let place = query.place else { return }
        query.returnPlace = query.placeFromField && place != .selection && place != .files
            ? (place, query.placeFilter) : nil
    }

    /// The field put away, whatever it was doing, a command's answer too.
    func close() {
        rememberPlace()
        if query.place == .files { cancelFileAnswer() }
        endAnswer()
        fileSelected.removeAll()
        query.acting = nil
        query.revealed = nil
        query.shown = [:]
        query.edit = nil
        query.stock = PlaceStock()
        query.form = nil
        query.place = nil
        editing = false
        dropScope()
        query.searchOver = nil
        query.settingUp = false
        typed = ""
        picked = nil
    }

    /// A clip, into the page's box or onto the clipboard.
    func paste(_ clip: Clips.Clip, plain: Bool = false, copyOnly: Bool = false) {
        let into = pastesIntoPage && !copyOnly
        let tab = active
        close()
        Clips.shared.put(clip, plain: plain)
        guard into, let tab, let web = tab.builtPage else {
            return
        }
        // Once the page has the keyboard back (see ContentView.handBack).
        // Once the page has the keyboard back; only the text is on the
        // clipboard for a plain paste, so the same paste takes it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            web.window?.makeFirstResponder(web)
            NSApp.sendAction(#selector(NSText.paste(_:)), to: web, from: nil)
        }
    }

    /// An emoji, typed into the page's box, or copied.
    func paste(emoji: Emoji.One, copyOnly: Bool = false) {
        Emoji.used(emoji.glyph)
        let into = pastesIntoPage && !copyOnly
        let tab = active
        close()
        guard into, let tab, let web = tab.builtPage else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(emoji.glyph, forType: .string)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            web.window?.makeFirstResponder(web)
            // Typed, as the keyboard's viewer types it: the clipboard keeps
            // what was on it, and ⌘Z takes it back out.
            let quoted = (try? String(data: JSONSerialization.data(withJSONObject: [emoji.glyph]), encoding: .utf8)) ?? "[\"\"]"
            web.run("document.execCommand('insertText', false, \(quoted)[0])")
        }
    }

    // MARK: actions

    /// The row Return takes now, in whatever the field is showing: what
    /// the list is narrowed to, while that is dropped from the field's end.
    var fieldActions: [FieldAction] {
        query.choosingFilter ? filterActions : rowActions
    }

    /// Window commands belong to Actions, never to an empty field's Return.
    var fieldMenuActions: [FieldAction] {
        var actions = fieldActions
        // A private window never becomes normal, even with no tabs left.
        // Keep a way back in its field's Actions as well as File and Cmd-N.
        if privateBrowsing, query.place == nil, !query.choosingFilter,
           !actions.contains(where: { $0.id == "newWindow" }) {
            actions.append(FieldAction(id: "newWindow", title: "New Window", keys: Keymap.shared.text(.newWindow),
                                       symbol: "yab.window.plus", group: 1) {
                self.query.acting = nil
                self.newWindow()
            })
        }
        return actions
    }

    /// What can be done to what is chosen, whatever list is up over it.
    var rowActions: [FieldAction] {
        // Rows picked together: the one act on all of them (PlacePicks).
        if let picked = pickedAction { return [picked] }
        if query.place == .selection, query.answering { return query.choosingModel ? answerModels : answerActions }
        if emojiWords != nil {
            let list = placeEmoji
            guard list.indices.contains(query.spot) else { return [] }
            let one = list[query.spot]
            // Copying is said once: as what Return does, or, where Return
            // pastes, as its own row.
            var out = [FieldAction(id: "paste", title: pastesIntoPage ? "Paste to Page" : "Copy Emoji", symbol: pastesIntoPage ? "yab.clipboard.right" : "yab.copyframe.smile") { self.paste(emoji: one) }]
            if pastesIntoPage {
                out.append(FieldAction(id: "copy", title: "Copy Emoji", keys: Keymap.shared.text(.fieldCopy), symbol: "yab.copyframe.smile") { self.paste(emoji: one, copyOnly: true) })
            }
            out.append(FieldAction(id: "second", title: "Copy Unicode", keys: Keymap.shared.text(.fieldSecond), symbol: "yab.copyframe.hash", group: 1) {
                self.close()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Emoji.unicode(one.glyph), forType: .string)
            })
            let pinned = Emoji.pinned.contains(one.glyph)
            out.append(FieldAction(id: "pin", title: pinned ? "Unpin" : "Pin", keys: Keymap.shared.text(.fieldPin), symbol: pinned ? "pin.slash" : "pin") {
                Emoji.pin(one.glyph)
                // The chosen tile stays the emoji, wherever pinning took it.
                self.query.spot = self.placeEmoji.firstIndex(of: one) ?? 0
            })
            if Emoji.recent.contains(one.glyph) {
                out.append(FieldAction(id: "delete", title: "Remove from Frequently Used", keys: Keymap.shared.text(.fieldDelete), symbol: "yab.clock.x") {
                    Emoji.forget(one.glyph)
                    self.query.spot = min(self.query.spot, max(0, self.placeEmoji.count - 1))
                })
            }
            return out
        }
        if let place = query.place, place != .clipboard, place != .emoji, place != .selection, place != .mail {
            if query.edit != nil { return editActions }
            if let empty = placeEmpty { return empty.actions }
            if let item = placeItem { return placeActions(item) }
            return []
        }
        if query.place == .clipboard {
            let list = placeClips
            guard list.indices.contains(query.spot) else { return clipEmpty?.actions ?? [] }
            let clip = list[query.spot]
            var out = [FieldAction(id: "paste", title: pastesIntoPage ? "Paste to Page" : "Copy to Clipboard", symbol: pastesIntoPage ? "yab.clipboard.right" : "yab.copy") { self.paste(clip) }]
            if pastesIntoPage {
                out.append(FieldAction(id: "copy", title: "Copy to Clipboard", keys: Keymap.shared.text(.fieldCopy), symbol: "yab.copy") { self.paste(clip, copyOnly: true) })
            }
            if clip.kind != .image {
                out.append(FieldAction(id: "plain", title: pastesIntoPage ? "Paste as Plain Text" : "Copy as Plain Text", keys: Keymap.shared.text(.fieldAlternate), symbol: "textformat.abc") {
                    self.paste(clip, plain: true)
                })
            }
            if let page = clip.page {
                out.append(FieldAction(id: "page", title: "Open Page It Came From", keys: Keymap.shared.text(.fieldPage), symbol: "yab.page.left") {
                    self.close()
                    self.open(page, foreground: true)
                })
            }
            if clip.kind == .link, let url = URL(string: clip.text) {
                out.append(FieldAction(id: "link", title: "Open Link", keys: clip.page == nil ? Keymap.shared.text(.fieldPage) : "", symbol: "yab.arrowout") {
                    self.close()
                    self.open(url, foreground: true)
                })
            }
            out.append(FieldAction(id: "pin", title: clip.pinned ? "Unpin" : "Pin", keys: Keymap.shared.text(.fieldPin), symbol: clip.pinned ? "pin.slash" : "pin") {
                Clips.shared.pin(clip)
                // The chosen row stays the clip, wherever pinning took it.
                if let index = self.placeClips.firstIndex(where: { $0.id == clip.id }) { self.query.spot = index }
            })
            out.append(FieldAction(id: "delete", title: "Delete", keys: Keymap.shared.text(.fieldDelete), symbol: "trash") {
                self.did(Clips.shared.deleteUndoably(clip))
                self.query.spot = min(self.query.spot, max(0, self.placeClips.count - 1))
            })
            out.append(FieldAction(id: "clear", title: "Delete All Unpinned…", keys: Keymap.shared.text(.fieldClear), symbol: "yab.clipboard.x") { self.askClear() })
            return out
        }
        guard let index = query.current, offers.indices.contains(index) else { return [] }
        let offer = offers[index]
        // Mail's rows: one action each (MailField).
        if case .page(let what) = offer.kind, what.hasPrefix("mail:") {
            return Browser.mailRows[String(what.dropFirst(5))].map { mailActions($0.row) } ?? []
        }
        // ⇧⌘F's, and a favorite's ⌥⌘↑ and ⌥⌘↓ (FieldFavorites).
        return pageRowActions(offer, plainActions(offer) + fallbackActions(offer))
    }

    /// What a row of the plain list can have done to it, by its kind.
    private func plainActions(_ offer: Suggestion) -> [FieldAction] {
        let take = { (way: Way) in { @MainActor in self.take(offer, way) } }
        switch offer.kind {
        case .open:
            let owner = offer.tab.flatMap { BrowserWindows.shared.owner(of: $0) }
            let elsewhere = owner.map { $0.browser !== self } ?? false
            // Split View's field: the tab goes beside the page, from here or
            // brought over from its window.
            let beside = asked == .split && offer.tab.flatMap { id in
                tabs.first { $0.id == id } ?? owner?.browser.tabs.first { $0.id == id }
            }.map(splitTakes) == true
            // A small window's field: the row's page opens in that window.
            let guest = fieldGuest != nil && !beside
            var out = [FieldAction(id: "switch", title: guest ? Browser.openWords(nil) : beside ? Browser.openWords(.split) : elsewhere ? "Switch to Other Window" : "Switch to Tab",
                                   symbol: guest ? Browser.openSymbol(nil) : beside ? "yab.split.plus" : elsewhere ? "yab.window.right" : "yab.tab.right", run: take(.here))]
            if !beside, splitsBeside, offer.tab != activeID, offer.tab != active.flatMap({ partner(of: $0)?.id }) {
                out.append(FieldAction(id: "split", title: Browser.openWords(.split), keys: Keymap.shared.text(.fieldAlternate), symbol: Browser.openSymbol(.split), run: take(.split)))
            }
            if let url = offer.url { out.append(copyLink(url)) }
            if let id = offer.tab, let tab = tabs.first(where: { $0.id == id }) {
                out += engineActions(for: tab)
                out.append(FieldAction(id: "closetab", title: "Close Tab", symbol: "yab.tab.x") { self.close(tab); self.typed = self.typed })
            } else if let id = offer.tab, let owner = BrowserWindows.shared.owner(of: id),
                      let tab = owner.browser.tabs.first(where: { $0.id == id }) {
                if owner.browser.spaceID == spaceID, !tab.shy, !tab.onCall, owner.browser.partner(of: tab) == nil {
                    out.append(FieldAction(id: "movehere", title: "Move Tab Here", keys: Keymap.shared.text(.fieldMove), symbol: "yab.tab.left", featured: true) {
                        self.editing = false
                        _ = BrowserWindows.shared.move(tab, from: owner.browser, to: self)
                    })
                }
                if let url = tab.address {
                    out.append(FieldAction(id: "copyhere", title: "Open Copy Here", symbol: "yab.tabs.plus") {
                        self.editing = false
                        self.arrive(url)
                    })
                }
            }
            return out
        case .visited, .known, .address, .search, .suggested, .asked, .site:
            var out = [FieldAction(id: "open", title: self.openWords(asking), symbol: self.openSymbol(asking), run: take(.here))]
            if instantWords != nil {
                out.append(FieldAction(id: "instant", title: "Open Top Result", keys: Keymap.shared.text(.fieldMove), symbol: "arrow.up.right", featured: true) { _ = self.submitInstant() })
            }
            out.append(FieldAction(id: "behind", title: "Open in Background Tab", keys: Keymap.shared.text(.fieldCopy), symbol: "yab.tab.down", run: take(.behind)))
            if !fresh { out.append(FieldAction(id: "ahead", title: "Open in New Tab", keys: Keymap.shared.text(.fieldAhead), symbol: "yab.tab.plus", run: take(.ahead))) }
            if asked != .split, splitsBeside {
                out.append(FieldAction(id: "split", title: Browser.openWords(.split), keys: Keymap.shared.text(.fieldAlternate), symbol: Browser.openSymbol(.split), run: take(.split)))
            }
            if let url = offer.url { out.append(copyLink(url)) }
            if forgettable(offer) {
                // A Frequent row only leaves Frequent; any other page is
                // deleted from the history, History's list too.
                out.append(FieldAction(id: "forget", title: offer.frequent == nil ? "Delete from History" : "Remove",
                                       keys: Keymap.shared.text(.fieldForget), symbol: "minus", danger: offer.frequent == nil) {
                    self.forget(offer)
                })
            }
            return out
        case .quickAction:
            var out = [FieldAction(id: "open", title: self.openWords(asking ?? .tab), symbol: self.openSymbol(asking ?? .tab), run: take(.here))]
            out.append(FieldAction(id: "behind", title: "Open in Background Tab", keys: Keymap.shared.text(.fieldCopy), symbol: "yab.tab.down", run: take(.behind)))
            if let url = offer.url { out.append(copyLink(url)) }
            return out
        case .command(.newWindow):
            return [FieldAction(id: "newWindow", title: "New Window", keys: Keymap.shared.text(.newWindow),
                                symbol: "yab.window.plus", run: take(.here))]
        case .command(let command):
            // Dark Page says what it does on this site: Turn Off for it, or On.
            let title = command == .darkPage ? darkPageAction : "Run Command"
            return [FieldAction(id: "run", title: title, keys: command == .pasteAndMatchStyle ? command.keys : "",
                                symbol: command.symbol, run: take(.here))]
        case .mailAccount:
            return [FieldAction(id: "open", title: "Go to Account", symbol: "yab.mail.right", run: take(.here))]
        case .setting:
            return [FieldAction(id: "run", title: "Open Settings", symbol: "gearshape", run: take(.here))]
        case .sum:
            return [FieldAction(id: "copy", title: "Copy Answer", symbol: "yab.copyframe.text", run: take(.here))]
        case .place(let place):
            let keys = place.shortcut.flatMap { Keymap.shared.keys($0)?.text } ?? "⇥"
            var out = [FieldAction(id: "enter", title: "Open \(place.title)", keys: keys, symbol: place.symbol, run: take(.here))]
            // Files' temporary row in Now is a place, rather than a hint.
            // Give it the same Done as the other notifications, without
            // offering Done on a favorite or a typed destination.
            if place == .downloads, !offer.favorite, typed.isEmpty,
               query.place == nil, query.scope == nil, downloadNews(now: Date()) != nil {
                out.append(FieldAction(id: "done", title: "Done", keys: Keymap.shared.text(.fieldDone), symbol: "yab.check") {
                    DownloadNews.finish()
                    self.picked = nil
                    self.query.pointed = nil
                    self.query.acting = nil
                    self.typed = ""
                })
            }
            return out
        case .within(let place):
            return [FieldAction(id: "enter", title: "Search \(place.title)", symbol: place.symbol, run: take(.here))]
        case .clip(let id):
            guard let clip = Clips.shared.items.first(where: { $0.id == id }) else { return [] }
            if clip.kind == .link, typed.isEmpty, let url = URL(string: clip.text) {
                return [FieldAction(id: "open", title: self.openWords(asking), symbol: self.openSymbol(asking), run: take(.here)), copyLink(url)]
            }
            var out = [FieldAction(id: "paste", title: pastesIntoPage ? "Paste to Page" : "Copy to Clipboard", symbol: pastesIntoPage ? "yab.clipboard.right" : "yab.copy", run: take(.here))]
            if pastesIntoPage {
                out.append(FieldAction(id: "copy", title: "Copy to Clipboard", keys: Keymap.shared.text(.fieldCopy), symbol: "yab.copy") { self.paste(clip, copyOnly: true) })
            }
            return out
        case .request(let index):
            let title = request(index)?.button ?? "Run"
            return [FieldAction(id: "run", title: title, symbol: "arrow.up.right", run: take(.here))]
        case .page(let what) where what.hasPrefix("menu:openChatProject:"):
            return projectActions(String(what.dropFirst("menu:openChatProject:".count)))
        case .page(let what) where what.hasPrefix("menu:"):
            return [FieldAction(id: "run", title: "Run Command",
                                symbol: MenuCommands.symbol(forTargetID: String(what.dropFirst(5))), run: take(.here))]
        case .page("wrapped"):
            return [FieldAction(id: "run", title: "Play", symbol: "gamecontroller", run: take(.here))]
        case .page("mail-now"):
            return mailNowActions(primary: take(.here))
        case .page, .task, .ask:
            // The verb alone ("Ask Claude"): the row says the quoted words,
            // and in the foot's pill they stretched it across the card.
            let verb = offer.key.components(separatedBy: " \u{201C}").first ?? offer.key
            var out = [FieldAction(id: "run", title: verb, symbol: "arrow.up.right", run: take(.here))]
            if instantWords != nil {
                out.append(FieldAction(id: "instant", title: "Open Top Result", keys: Keymap.shared.text(.fieldMove), symbol: "arrow.up.right", featured: true) { _ = self.submitInstant() })
            }
            return out
        case .hint(let id):
            guard let hint = Hints.shared.row(id) ?? Promises.shared.upcoming(now: Hints.now).first(where: { $0.id == id }) else { return [] }
            // Handed to the agent: ↩ is its chat, ⌫ puts the row away.
            if let session = Browser.handedChat(id) {
                let done = session.state == .done
                return [
                    FieldAction(id: "open", title: done ? "Open Answer" : "Open Chat", symbol: done ? "bubble.left" : "yab.chat.right", run: take(.here)),
                    FieldAction(id: "done", title: "Done", keys: Keymap.shared.text(.fieldDone), symbol: "yab.check") {
                        Hints.shared.opened(session.id, by: "done")
                        self.typed = ""
                    },
                ]
            }
            let joining = HintList.joining(hint, now: Hints.now)
            if Hints.promise(hint) { return promiseActions(hint, offer: offer) }
            if hint.local {
                // yab's own: over a page it opens in a tab of its own, and
                // where a tab is there already, it goes to that one.
                let there = Noticing.shared.openTab(for: hint) != nil
                var out = [FieldAction(id: "open", title: joining ? "Join" : there ? "Switch to Tab" : self.openWords(askingNew ? asking : .tab),
                                       symbol: joining ? "arrow.up.right" : there ? "yab.tab.right" : self.openSymbol(askingNew ? asking : .tab), run: take(.here))]
                if let doIt = doIt(hint) { out.append(doIt) }
                // Not Today and Done are one for what yab noticed: it is
                // about today, and tomorrow is worked out afresh.
                out.append(FieldAction(id: "later", title: "Not Today", keys: Keymap.shared.text(.fieldAlternate), symbol: "yab.calendar.right") { Noticing.shared.hideToday(hint); self.typed = "" })
                out.append(FieldAction(id: "done", title: "Done", keys: Keymap.shared.text(.fieldDone), symbol: "yab.check") { Noticing.shared.hideToday(hint); self.typed = "" })
                // A renewal you mean to keep: quiet until next year's.
                if Noticing.Kind.of(hint) == .renewal, let host = hint.url?.host() {
                    out.append(FieldAction(id: "next-year", title: "Ask Again Next Year", symbol: "clock") {
                        Purchases.shared.askNextYear(host)
                        Noticing.shared.hideToday(hint)
                        self.typed = ""
                    })
                }
                if hint.source == .habit {
                    out.append(FieldAction(id: "never", title: "Don’t Suggest This", symbol: "eye.slash") { Hints.shared.never(hint); self.typed = "" })
                } else {
                    if let sender = hint.sender {
                        out.append(FieldAction(id: "never-person", title: "Don’t Show Mail from \(sender.name)", symbol: "yab.person.minus") { Hints.shared.never(hint, person: true); self.typed = "" })
                    }
                    out.append(FieldAction(id: "never", title: "Don’t Show Things Like This", symbol: "yab.eye.slash") { Hints.shared.never(hint); self.typed = "" })
                }
                if let url = hint.url { out.append(copyLink(url)) }
                return out
            }
            if hint.id == Hints.connectID {
                return [
                    FieldAction(id: "open", title: "Open", symbol: "arrow.up.right", run: take(.here)),
                    FieldAction(id: "dismiss", title: "Don’t Show This", symbol: "yab.x") { Hints.shared.dismiss(hint); self.typed = "" },
                ]
            }
            if hint.id == PhoneBeta.hintID {
                let phone = PhoneBetaState.shared.phone
                var out = [FieldAction(id: "open", title: "Copy URL", symbol: "link", run: take(.here))]
                // Beside the code the arrows turn it; the compact card shows no
                // code, so its way to the other phone is that phone's link.
                if prefs.compactField {
                    out.append(FieldAction(id: "phone", title: "Copy \(phone.other.name) URL", symbol: "link") {
                        PhoneBeta.copy(phone.other, in: self)
                    })
                } else {
                    out.append(FieldAction(id: "phone", title: "iPhone or Android", keys: "←→", symbol: "iphone", featured: true) {
                        PhoneBetaState.shared.turn()
                    })
                }
                if phone == .iPhone {
                    out.append(FieldAction(id: "testflight", title: "Open TestFlight Page", symbol: "yab.globe.right") {
                        let asking = self.asking
                        self.close()
                        self.place(PhoneBeta.link, asking, from: self.active)
                    })
                }
                out.append(FieldAction(id: "dismiss", title: "Don’t Show This", symbol: "yab.x") { Hints.shared.dismiss(hint); self.typed = "" })
                return out
            }
            var out = [FieldAction(id: "open", title: joining ? "Join" : hint.url == nil ? "Start" : self.openWords(asking),
                                   symbol: joining || hint.url == nil ? "arrow.up.right" : self.openSymbol(asking), run: take(.here))]
            if let doIt = doIt(hint) { out.append(doIt) }
            if hint.setup {
                out.append(FieldAction(id: "dismiss", title: "Don’t Show This", symbol: "yab.x") { Hints.shared.dismiss(hint); self.typed = "" })
                return out
            }
            let now = Hints.now
            let later = Hints.laterToday(from: now)
            out.append(FieldAction(id: "later", title: later == now.addingTimeInterval(3 * 3600) ? "In 3 Hours" : "Later Today", keys: Keymap.shared.text(.fieldAlternate), symbol: later == now.addingTimeInterval(3 * 3600) ? "yab.clock.right" : "yab.clock") {
                Hints.shared.putOff(hint, until: later)
                self.typed = ""
            })
            out.append(FieldAction(id: "tomorrow", title: "Tomorrow Morning", symbol: "yab.sun") {
                Hints.shared.putOff(hint, until: Hints.tomorrowMorning(from: now))
                self.typed = ""
            })
            out.append(FieldAction(id: "done", title: "Done", keys: Keymap.shared.text(.fieldDone), symbol: "yab.check") { Hints.shared.finish(hint); self.typed = "" })
            out.append(FieldAction(id: "never", title: "Don’t Show Things Like This", symbol: "yab.eye.slash") { Hints.shared.never(hint); self.typed = "" })
            return out
        }
    }

    /// A row of Now's own Do It, Later and Done, for its thread's card over
    /// the page (MailThreadPeek): the same actions ⌘K lists for it.
    func hintPeekActions(_ id: String) -> [FieldAction] {
        let all = plainActions(Suggestion(key: id, title: "", url: nil, kind: .hint(id)))
        return ["hand", "later", "done"].compactMap { want in all.first { $0.id == want } }
    }

    /// Do It: the row given to the agent to see through in tabs of its
    /// own, while you stay where you are. No chat opens; the task is a
    /// folder of Today's, and the row says "On it", then "Needs you" while
    /// it waits on a yes. Anything that sends, pays, deletes or uploads
    /// waits for that yes. Nothing for a row with nothing to do: a link
    /// copied, a page from an iPhone, a habit, getting started.
    func doIt(_ hint: Hint) -> FieldAction? {
        guard Agents.ready, !hint.setup, hint.copied == nil, hint.phone == nil, hint.source != .habit,
              !hint.id.hasPrefix("task."), !hint.id.hasPrefix("wake."), Browser.handedChat(hint.id) == nil else { return nil }
        return FieldAction(id: "hand", title: "Do It", keys: Keymap.shared.text(.fieldCopy), symbol: "agent.face", featured: true) {
            // The field stays: the row's end turns to "On it" where you
            // pressed, and that is the word that it started.
            // Its chat begins with the row as a card over "Do It", not
            // with the words the agent is told (Browser.handed).
            guard let session = Agents.shared.task(Browser.doItWords(hint, now: Hints.now), context: [], on: nil,
                                                   said: "Do It", carrying: [Browser.handed(hint, now: Hints.now).label],
                                                   name: hint.title) else { return }
            if Hints.promise(hint) { Promises.shared.acted(hint.id) }
            // The row's end says it, the row chosen where it was: only its
            // word changes in the rows on screen, nothing is listed anew.
            withAnimation(.easeOut(duration: 0.2)) {
                Hints.shared.hand(hint.id, to: session.id)
                self.query.offers = self.query.offers.map { offer in
                    guard case .hint(let id) = offer.kind, id == hint.id else { return offer }
                    var said = offer
                    said.handed = Hints.shared.handedWords(id)
                    return said
                }
            }
        }
    }

    /// The task a row of Now was handed to, while its chat is the row's
    /// place: at work, asking, or done and not opened. One that failed or
    /// was stopped gives the row back, Do It and all.
    static func handedChat(_ id: String) -> Agents.Session? {
        guard let session = Hints.shared.handedSession(id) else { return nil }
        return session.state.live || (session.state == .done && Hints.shared.handedWords(id) == "Done") ? session : nil
    }

    /// The row as its task's chat shows it over "Do It", the same card on
    /// the Mac and the iPhone (SyncHanded): its words, the gray line under
    /// them, and where it came from.
    static func handed(_ hint: Hint, now: Date) -> SyncHanded {
        let host: String = switch hint.icon {
        case .site(let host): host
        case .picture(_, let site): site ?? ""
        default: ""
        }
        // "Gmail · From Now": where it came from, then where it was handed from.
        let site = host.isEmpty ? nil : host.hasPrefix("mail.google.") ? "Gmail" : Browser.siteName(host)
        let from = [site, "From Now"].compactMap { $0 }.joined(separator: " · ")
        return SyncHanded(host: host, title: hint.title, detail: HintList.detail(hint, now: now), from: from)
    }

    /// What the agent is told a row is, all of it: the words said, who to,
    /// when, where, and where to stop.
    nonisolated static func doItWords(_ hint: Hint, now: Date) -> String {
        let stop = "Stop before anything is sent, paid, deleted or uploaded: the user says yes to that themselves."
        let place = (hint.join ?? hint.url)?.absoluteString ?? ""
        let said = hint.quote.map { "«\($0)»" } ?? ""
        let who = hint.sender.map { "\($0.name) <\($0.address)>" } ?? ""
        if hint.id.hasPrefix("promise.mine.") {
            return """
            Keep a promise the user made. They wrote \(said)\(who.isEmpty ? "" : " to " + who), \(hint.detail). It was said at \(place). \
            Do what was promised: find the file, link or answer it needs (their Downloads, Drive, open tabs, mail), and write the \
            reply in their own voice right where they said it, with it attached. \(stop)
            """
        }
        if hint.id.hasPrefix("promise.theirs.") {
            return """
            \(who) promised the user \(said), \(hint.detail), and hasn't sent it. Write a short, friendly nudge where they said \
            it (\(place)) asking for it. \(stop)
            """
        }
        if Noticing.Kind.of(hint) == .renewal {
            return """
            Stop this subscription from renewing: \(hint.title) (\(hint.detail)). The user hasn't opened it lately. Open the \
            merchant's billing or subscription settings \(place.isEmpty ? "" : "(start at " + place + ")") in your own tab, signed in \
            as the user, and find where the plan is canceled or auto-renew turned off. Press up to the merchant's last button and stop \
            there: Yab asks the user before it. Never pay, never change the plan to another, never type a card. Say what changes \
            and until when they keep it.
            """
        }
        if Noticing.Kind.of(hint) == .meeting {
            return """
            Prepare the user for the meeting "\(hint.title)"\(hint.due.map { " at " + $0.englishFormatted(date: .omitted, time: .shortened) } ?? ""): \
            from their mail with these people, notes of past calls and what is open between them, write a short brief they can \
            read in a minute. \(place.isEmpty ? "" : "The meeting: " + place + ".") Send nothing.
            """
        }
        return ["Look into this and take care of it: " + hint.title, hint.detail, said, place, stop]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A promise's row: Do It, then Reply (yours) or Nudge (theirs, late),
    /// Done for good, Tomorrow Morning, and the two that teach: Not a
    /// Promise and Not From the person.
    private func promiseActions(_ hint: Hint, offer: Suggestion) -> [FieldAction] {
        let theirs = hint.id.hasPrefix("promise.theirs.")
        let open = { self.take(offer, .here) }
        var out: [FieldAction] = []
        out.append(FieldAction(id: "open", title: theirs ? "Nudge" : "Reply", symbol: theirs ? "arrow.up.right" : "yab.reply") {
            if theirs { Promises.shared.nudged(hint.id) } else { Promises.shared.acted(hint.id) }
            open()
        })
        if let doIt = doIt(hint) { out.append(doIt) }
        out.append(FieldAction(id: "done", title: "Done", keys: Keymap.shared.text(.fieldDone), symbol: "yab.check") {
            Promises.shared.done(hint)
            self.typed = ""
        })
        out.append(FieldAction(id: "later", title: "Tomorrow Morning", keys: Keymap.shared.text(.fieldAlternate), symbol: "yab.sun") {
            Promises.shared.putOff(hint.id, until: Hints.tomorrowMorning(from: Hints.now))
            Hints.shared.compose()
            self.typed = ""
        })
        out.append(FieldAction(id: "not", title: "Not a Promise", symbol: "yab.chat.x") {
            Promises.shared.notAPromise(hint)
            self.typed = ""
        })
        if let sender = hint.sender {
            out.append(FieldAction(id: "never-person", title: "Not From \(sender.name)", symbol: "person") {
                Hints.shared.never(hint, person: true)
                self.typed = ""
            })
        }
        return out
    }

    /// The chosen row's link, as ⇧⌘C copies a page's: without the
    /// tracking a link carries, and said in the corner, since the field
    /// closes over it and nothing else on screen answers.
    private func copyLink(_ url: URL) -> FieldAction {
        FieldAction(id: "copylink", title: "Copy URL", keys: Keymap.shared.text(.fieldSecond), symbol: "link") {
            self.close()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Diary.shareable(url).absoluteString, forType: .string)
            self.toaster.pop(feedback: .success)
        }
    }

    /// Delete All, asked first: what is gone doesn't come back.
    func askClear() {
        let unpinned = Clips.shared.items.filter { !$0.pinned }.count
        guard unpinned > 0 else { return }
        close()
        Task { @MainActor in
            let yes = await Questions.shared.ask(Question(
                title: "Delete \(unpinned) copied item\(unpinned == 1 ? "" : "s")?",
                detail: "Pinned items stay. This can’t be undone.",
                glyph: "trash", yes: "Delete", danger: true
            ))
            if yes { Clips.shared.clear() }
        }
    }

    /// A key the field answers itself, before the menus: ⌘K, ⇧⌘C on a
    /// row with a link, ⇧⌘F, ⌥⌘↑ and ⌥⌘↓ for Favorites, and in Clipboard
    /// History ⌘P, ⇧⌘P, ⌘O, ⌃X and ⌃⇧X.
    func fieldKey(_ event: NSEvent) -> Bool {
        let map = Keymap.shared
        if map.matches(event, .fieldActions) {
            showActions()
            return true
        }
        if map.matches(event, .fieldAbout), aboutOffered {
            showAbout()
            return true
        }
        if placeKey(event) { return true }
        if query.acting == nil, map.matches(event, .fieldMove) {
            if runAction("movehere") { return true }
            return submitInstant()
        }
        // ⇧⌘C on a row of the plain list is its Copy Link, as ⌘K says, and
        // not the menu's Copy Address of the page under the field. A row
        // with no link of its own leaves the key to the menu.
        if query.place == nil, emojiWords == nil, map.matches(event, .fieldSecond), runAction("copylink") { return true }
        // ⇧⌘F keeps the chosen row among Favorites or takes it out, ⌥⌘↑ and
        // ⌥⌘↓ move a favorite, from the list or over ⌘K's (FieldFavorites);
        // in History and Bookmarks, the page chosen there. Not in the other
        // places: Mail's ⇧⌘F is its draft's From there.
        if query.place == nil || query.place == .history || query.place == .bookmarks, emojiWords == nil {
            if map.matches(event, .fieldFavorite) { return favoriteKey("favorite") }
            if map.matches(event, .fieldFavoriteUp) { return favoriteKey("moveup") }
            if map.matches(event, .fieldFavoriteDown) { return favoriteKey("movedown") }
        }
        if emojiWords != nil {
            if map.matches(event, .fieldSecond) { return runAction("second") }
            if map.matches(event, .fieldPin) { return runAction("pin") }
            if map.matches(event, .fieldDelete) { return runAction("delete") }
            return false
        }
        guard query.place == .clipboard else { return false }
        if map.matches(event, .fieldFilter) {
            let all = Clips.Filter.allCases
            query.clipFilter = all[((all.firstIndex(of: query.clipFilter) ?? 0) + 1) % all.count]
            query.spot = 0
            return true
        }
        if map.matches(event, .fieldPin) { return runAction("pin") }
        if map.matches(event, .fieldPage) { return runAction("page") || runAction("link") }
        if map.matches(event, .fieldDelete) { return runAction("delete") }
        if map.matches(event, .fieldClear) { return runAction("clear") }
        return false
    }

    /// ⌘K: everything the chosen row can have done to it, in a panel of
    /// glass over the box's corner, above the foot's pill, as a launcher
    /// has it (FieldActionsPanel), with a search of its own at its foot.
    /// ⌘K again, or Escape, puts it away; from the About menu it takes
    /// that menu's place.
    func showActions() {
        if query.acting != nil {
            let about = query.choosingAbout
            query.acting = nil
            if !about { return }
        }
        let actions = fieldMenuActions
        guard actions.count > 1 || actions.contains(where: { $0.id == "newWindow" }) else { return }
        Browser.shownActions = actions.map(\.title)
        query.actionWords = ""
        query.acting = 0
    }

    /// A right-click on a row of the list (FieldRowMenu): that row chosen,
    /// and ⌘K's panel up over it, not a menu of its own; a row with only Return's action lists that one. A turn later
    /// than the click, which first puts away a panel already up (ClickAway).
    func showActions(forRow index: Int) {
        DispatchQueue.main.async { [self] in
            guard offers.indices.contains(index), !inert(index) else { return }
            query.acting = nil
            query.pointed = nil
            picked = index
            raiseActions()
        }
    }

    /// The same for a row of Clipboard History, by its place in the list.
    func showActions(forSpot spot: Int) {
        DispatchQueue.main.async { [self] in
            query.acting = nil
            query.spot = spot
            raiseActions()
        }
    }

    private func raiseActions() {
        let actions = fieldMenuActions
        guard !actions.isEmpty else { return }
        Browser.shownActions = actions.map(\.title)
        query.actionWords = ""
        query.acting = 0
    }

    /// ⇧⌘K, or the button at the foot's left: Yab's own menu in ⌘K's
    /// panel, risen from that corner, as a launcher keeps its About menu
    /// (FieldFoot). Again, or Escape, puts it away; from ⌘K's list it
    /// takes that list's place.
    func showAbout() {
        guard aboutOffered else { return }
        if query.acting != nil {
            let open = query.choosingAbout
            query.acting = nil
            if open { return }
        }
        query.choosingAbout = true
        query.actionWords = ""
        query.acting = 0
        Browser.shownActions = aboutActions.map(\.title)
    }

    /// Where the About menu is: the plain field, whose foot has nothing
    /// of its own at the left, no place's name and no answer.
    /// Not in Private, which has its own name there.
    var aboutOffered: Bool {
        query.place == nil && emojiWords == nil && !query.answering && !privateBrowsing
    }

    /// What the About menu holds: a word to us, what
    /// is new, the keys; a newer version, while there is one to look for
    /// or to restart into; then Yab itself and its settings.
    var aboutActions: [FieldAction] {
        func command(_ command: Command, group: Int = 0) -> FieldAction {
            FieldAction(id: command.rawValue, title: command.title, keys: command.keys, symbol: command.symbol, group: group) {
                self.close()
                command.run(in: self)
            }
        }
        // A page of Settings, the window brought up on it.
        func settings(_ page: SettingsPage, title: String, group: Int) -> FieldAction {
            FieldAction(id: page.rawValue, title: title, symbol: page.icon, group: group) {
                self.close()
                self.openSettings(page)
            }
        }
        var out = [
            command(.invite),
            command(.feedback),
            FieldAction(id: "changelog", title: "Changelog", symbol: "doc.text") {
                self.close()
                let site = Updater.site ?? URL(string: "https://yetanotherbrowser.com/")!
                _ = self.open(site.appending(path: "changelog"), foreground: true)
            },
            settings(.shortcuts, title: "Keyboard Shortcuts", group: 0),
        ]
        out += [Command.checkUpdates, .restartUpdate, .makeDefault].filter { $0.available(in: self) }.map { command($0, group: 1) }
        out.append(settings(.about, title: "About Yab", group: 2))
        // Where Settings opened last, as its menu item and ⌘, open it.
        out.append(FieldAction(id: "settings", title: Command.settings.title, keys: Command.settings.keys, symbol: Command.settings.symbol, group: 2) {
            self.close()
            Command.settings.run(in: self)
        })
        return out
    }

    /// ⌘K's list as its search leaves it: the actions whose words hold
    /// every word typed.
    var shownActions: [FieldAction] {
        // The About menu's own, the row's still what the foot's pill says.
        let all = query.choosingAbout ? aboutActions : fieldMenuActions
        let words = query.actionWords.lowercased().split(separator: " ")
        guard !words.isEmpty else { return all }
        return all.filter { action in words.allSatisfy { action.title.lowercased().contains($0) } }
    }

    /// What ⌘K last listed, for the bench.
    @MainActor static var shownActions: [String] = []

    /// ↩: the first action of what is chosen.
    func runPrimary() -> Bool {
        guard let first = fieldActions.first else { return false }
        first.run()
        return true
    }

    /// An action by its id, as its keys ask.
    func runAction(_ id: String) -> Bool {
        guard let action = fieldActions.first(where: { $0.id == id }) else { return false }
        action.run()
        return true
    }

    /// ⌫ and ⌥↩ on a row of Now: its advertised actions in ⌘K,
    /// or the visibly chosen row while nothing is typed.
    /// A search being written keeps its own Delete. True when taken.
    func hintKey(_ id: String) -> Bool {
        if query.acting != nil {
            guard query.actionWords.isEmpty, !query.choosingAbout,
                  !query.choosingModel, !query.choosingFilter,
                  let action = shownActions.first(where: { $0.id == id }) else { return false }
            // Capture the action before closing the panel, as Return does:
            // the menu explicitly chose its subject, even without arrows.
            query.acting = nil
            action.run()
            return true
        }
        // Use the same row the highlight, Return and the action menu use.
        // Query.pointed already ignores a list opening under a resting pointer.
        guard let current = query.current else { return false }
        let chosen = offers.indices.contains(current) ? offers[current] : nil
        if chosen?.kind == .place(.downloads), chosen?.favorite == true { return false }
        guard Browser.hintKeyed(typed: typed, bare: query.place == nil && query.scope == nil && query.acting == nil,
                                chosen: chosen?.kind, setup: { id in Hints.shared.row(id)?.setup ?? true })
        else { return false }
        return runAction(id)
    }

    /// Whether a hint row's own keys are asked for: an empty field of no
    /// place, site or ⌘K list, and a row of Now chosen that is something
    /// found, not getting started's (which has neither Done nor Later).
    nonisolated static func hintKeyed(typed: String, bare: Bool, chosen: Suggestion.Kind?, setup: (String) -> Bool) -> Bool {
        guard typed.isEmpty, bare else { return false }
        if chosen == .place(.downloads) || chosen == .page("mail-now") { return true }
        guard case .hint(let id)? = chosen else { return false }
        return !setup(id)
    }
}
