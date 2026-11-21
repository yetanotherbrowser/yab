import Foundation

// What the records sync carries say, as plain values: the fields each
// collection has, the values written for absent things and the rounding.
// The Mac turns its own files into these (SyncShapes.swift) and the iPhone
// its lists, so a record either writes is one the other reads as its own.

// MARK: - Spaces

/// A space's look: one of the Mac's swatches or a color of its own, and its
/// grain. Kept whole as the Mac wrote it, so the iPhone never rewrites a
/// field it doesn't know.
public struct SyncPaint: Equatable, Sendable {
    public var swatch: String
    /// "#RRGGBB", the color of its own.
    public var color: String
    /// How much grain, 0 for none.
    public var grain: Double
    public var transparency: Double
    public var colors: [String]
    public let raw: Value

    /// The Mac's SpacePaint as JSON: `grain` was on or off before it had an
    /// amount, `grainAmount` is the amount (Spaces.swift).
    public init?(_ value: Value) {
        guard let o = value.object, let swatch = o["swatch"]?.string, let color = o["color"]?.string else { return nil }
        self.swatch = swatch
        self.color = color
        grain = o["grainAmount"]?.number ?? (o["grain"]?.bool == true ? 0.35 : 0)
        let t = o["transparency"]?.number ?? 0
        transparency = t.isFinite ? min(1, max(0, t)) : 0
        colors = o["colors"]?.array?.compactMap(\.string) ?? []
        raw = value
    }
}

public struct SyncSpace: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Its emoji or a Mac's symbol name.
    public var icon: String
    public var ownSignIns: Bool
    public var signInWith: String?
    public var paint: SyncPaint?
    /// The other browser's place it was brought in from, "Arc:<id>".
    public var origin: String?
    /// Its place among the spaces (Order: base 62, sorts as a string).
    public var order: String?
    /// The engine the Mac's field searches with in it, "kagi", "custom";
    /// nil for the one in Settings › Search.
    public var search: String?
    /// The results page, with `%s` for the words, for "custom".
    public var searchCustom: String?
    /// The exact icon deliberately picked by a device that records intent.
    /// An old device's emoji echo has no matching choice (feedback #354).
    public var iconChoice: String?
    /// A new identity for every deliberate pick, including repeated ones.
    public var iconChoiceID: String?

    public var isFirst: Bool { id.uppercased() == SyncCollection.firstSpace }

    public init(id: String, name: String, icon: String, ownSignIns: Bool = false, paint: SyncPaint? = nil, origin: String? = nil, order: String? = nil,
                search: String? = nil, searchCustom: String? = nil, iconChoice: String? = nil, iconChoiceID: String? = nil, signInWith: String? = nil) {
        self.id = id; self.name = name; self.icon = icon; self.ownSignIns = ownSignIns
        self.paint = paint; self.origin = origin; self.order = order
        self.search = search; self.searchCustom = searchCustom
        self.iconChoice = iconChoice
        self.iconChoiceID = iconChoiceID
        self.signInWith = signInWith
    }

    /// As SyncShapes.spaces(from:) reads one: a UUID and a name, or nothing.
    public init?(_ record: Record) {
        guard record.alive(), UUID(uuidString: record.id) != nil, let name = record["name"]?.string else { return nil }
        self.init(id: record.id, name: name, icon: record["icon"]?.string ?? "🌐",
                  ownSignIns: record["ownSignIns"]?.bool ?? false,
                  paint: record["paint"].flatMap(SyncPaint.init), origin: record["origin"]?.string,
                  order: record["order"]?.string,
                  search: record["search"]?.string, searchCustom: record["searchCustom"]?.string,
                  iconChoice: record["iconChoice"]?.string, iconChoiceID: record["iconChoiceID"]?.string, signInWith: record["signInWith"]?.string)
    }

    /// As SyncShapes.spaces(_:orders:) writes one.
    public var fields: SyncFields {
        var fields: SyncFields = [
            "name": .string(name),
            "icon": .string(icon),
            "ownSignIns": .bool(ownSignIns),
            "signInWith": Value(signInWith),
            "paint": paint?.raw ?? .null,
            "origin": Value(origin),
            "order": Value(order),
        ]
        // Only a space with an engine of its own carries these, so every
        // other one is written as it was before spaces had one. Absent is
        // nil: the journal takes a field left out as gone (Record.update).
        if let search { fields["search"] = .string(search) }
        if let searchCustom { fields["searchCustom"] = .string(searchCustom) }
        if let iconChoice { fields["iconChoice"] = .string(iconChoice) }
        if let iconChoiceID { fields["iconChoiceID"] = .string(iconChoiceID) }
        return fields
    }
}

// MARK: - Rows

/// A tab of a space's row: pinned, kept or today's. Its page is not synced,
/// only what the row shows.
public struct SyncTab: Equatable, Sendable, Identifiable {
    public enum List: Sendable { case pinned, kept, today }

    public var id: String
    /// Its space's id (the record's `parent`).
    public var space: String
    public var order: String?
    public var url: String
    public var title: String
    /// The letter it is pinned under, or nil.
    public var pin: String?
    /// What you called it yourself.
    public var name: String?
    /// When it was last looked at on any device, in seconds since 1970, to
    /// five minutes: the largest wins.
    public var seen: Double?
    public var kept: Bool
    /// The folder it is in (a folder record's id).
    public var folder: String?
    /// What a live folder's tab is (the Mac's LiveMark), as the Mac wrote it.
    public var live: Value?
    public var customMark: String?
    /// How far down its page it was read, 0 to 1 (the Mac's Tab.depth).
    /// The iPhone only carries it.
    public var depth: Double?
    /// A pin's or a kept tab's home, the address it was pinned or kept at,
    /// and that page's title (the Mac's PinnedHome.swift). The iPhone only
    /// carries them, so its writes never drop the Mac's.
    public var home: String?
    public var homeTitle: String?
    /// The device a tab of today's is open on: each device keeps its own
    /// Today (docs/sync.md, "Today is each device's own"). Nil for pins and
    /// kept tabs, which every device shares, and for today's tabs written
    /// before Today was each device's, which count as a Mac's.
    public var device: String?

    public var list: List { pin != nil ? .pinned : kept ? .kept : .today }

    /// A new pin's letter, as the Mac's Tab.monogram makes it: its site's
    /// first, "•" for none.
    public static func monogram(_ url: String) -> String {
        let host = URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        return host.first.map { String($0).uppercased() } ?? "•"
    }

    /// Whether `device`'s rows show it: pins and kept tabs on every device;
    /// a tab of today's on the device it is open on, and one with no device
    /// (from before) on a Mac, never on an iPhone. No device asking: all.
    public func shown(to device: String?, mac: Bool) -> Bool {
        guard let device, list == .today else { return true }
        guard let owner = self.device else { return mac }
        return owner == device
    }
    /// The words a live folder's tab says at its end ("needs your review").
    public var liveWords: String? { live?.object?["words"]?.string }

    public init(id: String = UUID().uuidString, space: String, order: String? = nil, url: String, title: String, pin: String? = nil, name: String? = nil,
                seen: Double? = nil, kept: Bool = false, folder: String? = nil, live: Value? = nil, customMark: String? = nil,
                depth: Double? = nil, home: String? = nil, homeTitle: String? = nil, device: String? = nil) {
        self.id = id; self.space = space; self.order = order; self.url = url; self.title = title; self.pin = pin; self.name = name
        self.seen = seen; self.kept = kept; self.folder = folder; self.live = live; self.customMark = customMark
        self.depth = depth; self.home = home; self.homeTitle = homeTitle; self.device = device
    }

    /// As SyncShapes.row reads one: there, in a space, with an address.
    public init?(_ record: Record) {
        guard record.alive(), let space = record["parent"]?.string, let url = record["url"]?.string else { return nil }
        self.init(id: record.id, space: space, order: record["order"]?.string, url: url, title: record["title"]?.string ?? "",
                  pin: record["pin"]?.string, name: record["name"]?.string, seen: record["seen"]?.number,
                  kept: record["kept"]?.bool == true, folder: record["folder"]?.string, live: record["live"],
                  customMark: record["customMark"]?.string, depth: record["depth"]?.number, home: record["home"]?.string,
                  homeTitle: record["homeTitle"]?.string, device: record["device"]?.string)
    }

    /// The Mac rounds `seen` down to five minutes: the tab on screen is
    /// written as seen now on every save, and Tidy counts in hours.
    public static func round(seen: Double) -> Double { (seen / 300).rounded(.down) * 300 }

    /// As SyncShapes.rows writes one. `seen` is given as it is and rounded here.
    /// `device` only when there is one, so a record without it writes the
    /// same bytes as before (a field left out is cleared on the record).
    public var fields: SyncFields {
        var out: SyncFields = [
            "parent": .string(space),
            "order": Value(order),
            "url": .string(url),
            "title": .string(title),
            "pin": Value(pin),
            "name": Value(name),
            "seen": Value(seen.map(SyncTab.round(seen:))),
            "kept": kept ? .bool(true) : .null,
            "folder": Value(folder),
            "live": live ?? .null,
            "customMark": Value(customMark),
            "depth": Value(depth),
            "home": Value(home),
            "homeTitle": Value(home == nil ? nil : homeTitle),
        ]
        if list == .today, let device { out["device"] = .string(device) }
        return out
    }
}

/// The Mac's custom PNG bytes. The record remains in the account journal;
/// malformed, overlarge and unknown files cannot become a rendered mark.
public struct SyncIcon: Equatable, Sendable, Identifiable {
    public let id: String
    public let data: Data
    /// Present only for a public site icon; custom artwork has no origin.
    public let origin: URL?

    public init?(_ record: Record) {
        guard record.collection == SyncCollection.icon, record.alive(), Self.validName(record.id),
              let encoded = record["data"]?.string, encoded.utf8.count <= 64_000,
              let data = Data(base64Encoded: encoded), !data.isEmpty, data.count < 48_000 else { return nil }
        if let address = record["origin"]?.string {
            guard let url = URL(string: address), let normalized = Self.siteOrigin(url), normalized.absoluteString == address else { return nil }
            origin = normalized
        } else { origin = nil }
        id = record.id; self.data = data
    }

    public static func siteOrigin(_ url: URL) -> URL? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        var result = URLComponents()
        result.scheme = scheme; result.host = host
        if let port = parts.port, !(scheme == "http" && port == 80), !(scheme == "https" && port == 443) { result.port = port }
        return result.url
    }

    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128 && !name.hasPrefix(".") && name.hasSuffix(".png") &&
        name.unicodeScalars.allSatisfy { character in
            (65...90).contains(character.value) || (97...122).contains(character.value) ||
            (48...57).contains(character.value) || [45, 46, 95].contains(character.value)
        }
    }
}

/// A folder of a space's row. Made on a Mac; the iPhone shows it and folds
/// it, and never makes one.
public struct SyncFolder: Equatable, Sendable, Identifiable {
    public var id: String
    public var space: String
    /// Where it stands: its first tab's place.
    public var order: String?
    public var name: String?
    /// Open on the Mac. Folding it on the iPhone is the iPhone's own.
    public var open: Bool?
    /// The words searched, for a folder a search gathered (among today's).
    public var search: String?
    /// A folder made of today's tabs, among them.
    public var today: Bool?
    public var ordinaryToday: Bool?
    /// One of today's a ⌘-click made: it wears the page's site as its mark.
    public var linked: Bool?
    /// A live folder's source (the Mac's Live), as the Mac wrote it.
    public var live: Value?
    public var customMark: String?
    /// The optional color chosen for this folder, shared across devices.
    public var color: String?
    /// The folder containing this folder; `space` remains its owning space.
    public var folder: String?

    public init(id: String, space: String, order: String? = nil, name: String? = nil, open: Bool? = nil, search: String? = nil,
                today: Bool? = nil, ordinaryToday: Bool? = nil, linked: Bool? = nil, live: Value? = nil, customMark: String? = nil, color: String? = nil, folder: String? = nil) {
        self.id = id; self.space = space; self.order = order; self.name = name; self.open = open; self.search = search
        self.today = today; self.ordinaryToday = ordinaryToday; self.linked = linked; self.live = live; self.customMark = customMark; self.color = color; self.folder = folder
    }

    public init?(_ record: Record) {
        guard record.alive(), let space = record["parent"]?.string else { return nil }
        self.init(id: record.id, space: space, order: record["order"]?.string, name: record["name"]?.string, open: record["open"]?.bool,
                  search: record["search"]?.string, today: record["today"]?.bool, ordinaryToday: record["ordinaryToday"]?.bool, linked: record["linked"]?.bool, live: record["live"], customMark: record["customMark"]?.string,
                  color: record["color"]?.string,
                  folder: record["folder"]?.string)
    }

    public var fields: SyncFields {
        [
            "parent": .string(space),
            "order": Value(order),
            "name": Value(name),
            "open": Value(open),
            "search": Value(search),
            "today": Value(today),
            "ordinaryToday": Value(ordinaryToday),
            "linked": Value(linked),
            "live": live ?? .null,
            "customMark": Value(customMark),
            "color": Value(color),
            "folder": Value(folder),
        ]
    }
}

/// Two tabs side by side on a Mac (Split View). The iPhone has no split,
/// but keeps them so a Mac's pairs survive the iPhone's writes.
public struct SyncPair: Equatable, Sendable, Identifiable {
    public var first: String
    public var second: String
    public var space: String
    public var share: Double
    public var id: String { "\(first)|\(second)" }

    public init(first: String, second: String, space: String, share: Double) {
        self.first = first; self.second = second; self.space = space; self.share = share
    }

    public init?(_ record: Record) {
        let ids = record.id.split(separator: "|").map(String.init)
        guard record.alive(), ids.count == 2, let space = record["parent"]?.string else { return nil }
        self.init(first: ids[0], second: ids[1], space: space, share: record["share"]?.number ?? 0.5)
    }

    public var fields: SyncFields { ["parent": .string(space), "share": .number(share)] }
}

/// One space's row as the Mac shows it: pins, then the kept, then today's,
/// each in order (SyncShapes.row).
public struct SyncRow: Equatable, Sendable {
    public var space: String
    public var pins: [SyncTab]
    public var kept: [SyncTab]
    public var today: [SyncTab]
    public var folders: [String: SyncFolder]
    public var pairs: [SyncPair]
    /// Today's tabs of this space open on other devices, in order: not in
    /// this device's rows, there to look into and open a copy of here.
    public var elsewhere: [SyncTab]

    public var all: [SyncTab] { pins + kept + today }

    public init(space: String, pins: [SyncTab] = [], kept: [SyncTab] = [], today: [SyncTab] = [], folders: [String: SyncFolder] = [:], pairs: [SyncPair] = [],
                elsewhere: [SyncTab] = []) {
        self.space = space; self.pins = pins; self.kept = kept; self.today = today; self.folders = folders; self.pairs = pairs
        self.elsewhere = elsewhere
    }

    /// The row from the records, the Mac's way: tabs sorted by place then
    /// id, split by kind; a tab's folder only if that folder is there; a
    /// pair only if both its tabs are, each tab in one pair at most.
    /// `device`: the row as that device shows it (SyncTab.shown), today's
    /// tabs of the others in `elsewhere`.
    public init(space: String, tabs: [Record], folders: [Record], pairs: [Record], device: String? = nil, mac: Bool = true) {
        let placed = tabs.compactMap(SyncTab.init).filter { $0.space == space }.sorted(by: RecordShapes.placed)
        let mine = placed.filter { $0.shown(to: device, mac: mac) }
        self.elsewhere = placed.filter { !$0.shown(to: device, mac: mac) }
        let byFolder = Dictionary(folders.compactMap(SyncFolder.init).filter { $0.space == space }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var shown: [SyncTab] = []
        for var tab in mine {
            if let id = tab.folder, byFolder[id] == nil { tab.folder = nil }
            shown.append(tab)
        }
        self.space = space
        self.pins = shown.filter { $0.list == .pinned }
        self.kept = shown.filter { $0.list == .kept }
        self.today = shown.filter { $0.list == .today }
        self.folders = byFolder
        let at = Set(shown.map(\.id))
        var taken = Set<String>()
        self.pairs = pairs.compactMap(SyncPair.init).filter { $0.space == space }.sorted { $0.id < $1.id }.filter { pair in
            guard at.contains(pair.first), at.contains(pair.second), !taken.contains(pair.first), !taken.contains(pair.second) else { return false }
            taken.formUnion([pair.first, pair.second])
            return true
        }
    }
}

// MARK: - Bookmarks

public struct SyncBookmark: Equatable, Sendable, Identifiable {
    public var id: String
    /// Its folder's id, or `root`.
    public var parent: String
    public var order: String?
    public var title: String
    /// Nil for a folder.
    public var url: String?
    public var added: Double?
    public var space: String?
    public var importKey: String?
    /// A folder's bookmarks, in order, when read as a tree.
    public var children: [SyncBookmark]?

    public var isFolder: Bool { url == nil }

    /// One bookmark as a record says it, without its children.
    public init?(_ record: Record) {
        guard record.alive(), UUID(uuidString: record.id) != nil else { return nil }
        let folder = record["folder"]?.bool == true || record["url"] == nil
        self.init(id: record.id, parent: record["parent"]?.string ?? SyncCollection.root, order: record["order"]?.string,
                  title: record["title"]?.string ?? "", url: folder ? nil : record["url"]?.string, added: record["added"]?.number, space: record["space"]?.string, importKey: record["importKey"]?.string)
    }

    public init(id: String = UUID().uuidString, parent: String = SyncCollection.root, order: String? = nil, title: String, url: String?,
                added: Double? = nil, children: [SyncBookmark]? = nil, space: String? = nil, importKey: String? = nil) {
        self.id = id; self.parent = parent; self.order = order; self.title = title; self.url = url; self.added = added; self.children = children; self.space = space; self.importKey = importKey
    }

    /// As SyncShapes.bookmarks writes one.
    public var fields: SyncFields {
        [
            "parent": .string(parent),
            "order": Value(order),
            "title": .string(title),
            "url": Value(url),
            "folder": isFolder ? .bool(true) : .null,
            "added": Value(added),
            "space": Value(space),
            "importKey": Value(importKey),
        ]
    }
}

// MARK: - History

/// A place been to in the last two weeks, on any device. Counts stay on each
/// device; what syncs only ever adds.
public struct SyncVisit: Equatable, Sendable, Identifiable {
    /// The place's key: the address without www., scheme, query or fragment,
    /// lowercased (Address.pretty on the Mac).
    public var id: String
    public var url: String
    public var title: String
    /// Seconds since 1970, to the second: the largest wins.
    public var last: Double
    /// Asked for in the field rather than a link followed.
    public var typed: Bool

    public init(url: String, title: String, last: Double, typed: Bool = false) {
        self.init(id: URL(string: url).map(SyncVisit.key) ?? url.lowercased(), url: url, title: title, last: last, typed: typed)
    }

    /// A place by a key worked out already (the Mac's Visit.key).
    public init(id: String, url: String, title: String, last: Double, typed: Bool = false) {
        self.id = id; self.url = url; self.title = title; self.last = last; self.typed = typed
    }

    public init?(_ record: Record) {
        guard record.alive(), let url = record["url"]?.string, let last = record["last"]?.number else { return nil }
        id = record.id
        self.url = url
        title = record["title"]?.string ?? ""
        self.last = last
        typed = record["typed"]?.bool == true
    }

    /// As SyncShapes.visits writes one.
    public var fields: SyncFields {
        [
            "url": .string(url),
            "title": .string(String(title.prefix(300))),
            "last": .number(last.rounded(.down)),
            "typed": typed ? .bool(true) : .null,
        ]
    }

    /// Whether history keeps a place of this kind at all.
    public static func keeps(_ url: URL) -> Bool { url.scheme == "http" || url.scheme == "https" }

    /// The Mac's history key (`History.key(for:)`): the host without www.,
    /// an IPv6 address in brackets, a port that isn't the scheme's own
    /// (localhost:3000 and localhost:4000 are two places), and the path
    /// unless it is empty or "/". No query or fragment.
    public static func key(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString.lowercased() }
        var bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if bare.contains(":") { bare = "[\(bare)]" }
        if let port = url.port, port != (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : -1) {
            bare += ":\(port)"
        }
        let path = url.path()
        return (path.isEmpty || path == "/" ? bare : bare + path).lowercased()
    }

    /// The key a record's place has now, read from its address, a removed
    /// record's too. A Yab from before ports were part of the key still
    /// names a server's page without its port (`localhost/blog` for
    /// http://localhost:3000/blog), so its records' ids can differ from
    /// this. Nil without an address.
    public static func key(of record: Record) -> String? {
        guard let address = record.fields["url"]?.string, let url = URL(string: address) else { return nil }
        return key(url)
    }

    /// The place's key read from its address (`key(of:)`): the same for an
    /// older device's record of a page and a newer one's.
    public var place: String { URL(string: url).map(SyncVisit.key) ?? id }

    /// The key a Yab from before ports were part of it gives a place:
    /// `localhost/blog` for `localhost:3000/blog`, `[fd00::1]` for
    /// `[fd00::1]:3000`. Nil for a key without a port.
    public static func portless(_ key: String) -> String? {
        let site = String(key.prefix { $0 != "/" })
        let host = site.hasPrefix("[") ? String(site.prefix { $0 != "]" }) + "]" : String(site.prefix { $0 != ":" })
        guard host.count < site.count else { return nil }
        return host + String(key.dropFirst(site.count))
    }
}

// MARK: - Settings

public struct SyncSetting: Equatable, Sendable, Identifiable {
    /// The Mac's preferences key ("search.engine", "zoom.github.com").
    public var id: String
    /// Data comes as {"$data": base64}, dates as {"$date": seconds}.
    public var value: Value

    public init?(_ record: Record) {
        guard record.alive(), let value = record["value"] else { return nil }
        id = record.id
        self.value = value
    }
}

// MARK: - Whole collections, the Mac's way

/// The Mac's functions from a whole list to a collection's records, for
/// the iPhone's own list writes and to prove the two write the same thing.
public enum RecordShapes {
    public typealias Collection = [String: SyncFields]

    public static func placed(_ a: SyncTab, _ b: SyncTab) -> Bool { (a.order ?? "", a.id) < (b.order ?? "", b.id) }

    /// SyncShapes.spaces: each space with a key for its place, keeping every
    /// key it can from `previous`.
    public static func spaces(_ list: [SyncSpace], orders previous: [String: String]) -> Collection {
        let orders = Order.assign(list.map(\.id), previous: previous)
        var out: Collection = [:]
        for var space in list {
            space.order = orders[space.id]
            out[space.id] = space.fields
        }
        return out
    }

    public static func spaces(from records: [Record]) -> [SyncSpace] {
        records.compactMap(SyncSpace.init).sorted { ($0.order ?? "", $0.id) < ($1.order ?? "", $1.id) }
    }

    /// SyncShapes.rows for one space: its tabs in the order they stand,
    /// pins, kept then today's, each with a key; a folder stands where its
    /// first tab stands.
    public static func row(space: String, tabs: [SyncTab], folders: [String: SyncFolder], pairs: [SyncPair],
                           orders previous: [String: String]) -> (tabs: Collection, folders: Collection, pairs: Collection) {
        let orders = Order.assign(tabs.map(\.id), previous: previous)
        var outTabs: Collection = [:], outFolders: Collection = [:], outPairs: Collection = [:]
        for var tab in tabs {
            tab.space = space
            tab.order = orders[tab.id]
            outTabs[tab.id] = tab.fields
            var next = tab.folder
            var seen: Set<String> = []
            while let id = next, seen.insert(id).inserted, seen.count <= 5 {
                var folder = folders[id] ?? SyncFolder(id: id, space: space)
                guard folder.space == space else { break }
                if outFolders[id] == nil {
                    folder.order = orders[tab.id]
                    outFolders[id] = folder.fields
                }
                next = tab.kept && folder.search == nil && folder.today != true ? folder.folder : nil
            }
        }
        let ids = Set(tabs.map(\.id))
        for var pair in pairs where ids.contains(pair.first) && ids.contains(pair.second) {
            pair.space = space
            outPairs[pair.id] = pair.fields
        }
        return (outTabs, outFolders, outPairs)
    }

    /// SyncShapes.bookmarks: a tree, each level keyed in order.
    public static func bookmarks(_ tree: [SyncBookmark], orders previous: [String: String]) -> Collection {
        var out: Collection = [:]
        func walk(_ level: [SyncBookmark], parent: String) {
            let orders = Order.assign(level.map(\.id), previous: previous)
            for var mark in level {
                mark.parent = parent
                mark.order = orders[mark.id]
                out[mark.id] = mark.fields
                if let children = mark.children { walk(children, parent: mark.id) }
            }
        }
        walk(tree, parent: SyncCollection.root)
        return out
    }

    /// SyncShapes.bookmarks(from:): the tree put right first (Tree.repair),
    /// a bookmark whose folder went elsewhere at the top level.
    public static func bookmarks(from records: [Record]) -> [SyncBookmark] {
        let root = SyncCollection.root
        let living = records.filter { $0.alive() }
        var nodes = living.map { Tree.Node(id: $0.id, parent: $0["parent"]?.string ?? root, order: $0["order"]?.string ?? "V", moved: $0.stamps["parent"]) }
        for fix in Tree.repair(nodes, roots: [root], fallback: root) {
            if let i = nodes.firstIndex(where: { $0.id == fix.id }) {
                nodes[i].parent = fix.parent ?? root
                nodes[i].order = fix.order
            }
        }
        let byID = Dictionary(living.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func level(_ parent: String) -> [SyncBookmark] {
            Tree.children(of: parent, in: nodes).compactMap { node in
                guard let record = byID[node.id], UUID(uuidString: node.id) != nil else { return nil }
                let folder = record["folder"]?.bool == true || record["url"] == nil
                return SyncBookmark(id: node.id, parent: node.parent ?? root, order: node.order, title: record["title"]?.string ?? "",
                                    url: folder ? nil : record["url"]?.string, added: record["added"]?.number,
                                    children: folder ? level(node.id) : nil, space: record["space"]?.string, importKey: record["importKey"]?.string)
            }
        }
        return level(root)
    }

    /// SyncShapes.visits: places by their key.
    public static func visits(_ list: [SyncVisit]) -> Collection {
        var out: Collection = [:]
        for visit in list { out[visit.id] = visit.fields }
        return out
    }
}
