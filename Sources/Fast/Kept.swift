import AppKit
import SwiftUI

/// Folder colors for Customize Folder. Black is the legacy neutral value;
/// the picker shows it as no color and writes nil.
enum FolderTint: String, CaseIterable {
    case black, teal, blue, purple, yellow, pink, red, orange

    init(stored: String?) { self = stored.flatMap(FolderTint.init(rawValue:)) ?? .black }

    var stored: String? { self == .black ? nil : rawValue }
    var title: String { self == .black ? "No Color" : rawValue.capitalized }

    private var hex: String {
        switch self {
        case .black: "#292A2D"
        case .teal: "#11AF91"
        case .blue: "#119AD0"
        case .purple: "#7566AF"
        case .yellow: "#EAB51B"
        case .pink: "#DE7698"
        case .red: "#CC5162"
        case .orange: "#E47B4D"
        }
    }

    var swatch: Color { Color(nsColor: NSColor(hex: hex) ?? .black) }

    func ink(dark: Bool) -> Color {
        if dark { return swatch }
        let hex: String = switch self {
        case .black: "#292A2D"
        case .teal: "#08765F"
        case .blue: "#176D9C"
        case .purple: "#65558E"
        case .yellow: "#946A00"
        case .pink: "#A34365"
        case .red: "#A43348"
        case .orange: "#A84C23"
        }
        return Color(nsColor: NSColor(hex: hex) ?? .black)
    }

    func wash(dark: Bool) -> Color { swatch.opacity(dark ? 0.20 : 0.13) }
}

// Tabs that stay, the way Arc keeps its pinned rows. A pin is a square of
// five or six places you live in; a kept tab is a row with its title, as many
// as you like, above a line in the column: what is under the line is today's,
// and tidying up takes it when you leave it long enough (Tidy.swift); what is
// above it stays, whatever its age. ⌘W puts a kept tab to sleep, as it puts
// down a pin: the row keeps its place and the page is let go.
//
// The row is always in this order: the pins, the kept tabs, today's tabs,
// and last, an agent's folders (AgentFolders.swift). Among the kept, folders
// of yours (a Nest each), every folder one run of tabs; there are none among
// today's, which are gone by tomorrow. A folder of yours can be in another,
// as Arc's are, five deep at most: each row steps in a mark's width more,
// and the whole of a folder, its own tabs and its folders' tabs, is one run
// of the row. Dragging a row across the line keeps it or lets it go, and
// the line itself is a slot in the list like a folder's own row, so the
// rows step aside for it as for any other.

/// A folder of yours among the kept tabs. Each of its tabs holds it; there
/// is no list of folders apart from them, so a folder is wherever its tabs
/// are, a space's row, a parked one, the session file, and goes with the
/// last of them. A tab holds the folder it is right in; the folders that
/// folder is in are held through it (`parent`), so a folder with only
/// folders in it is still there for as long as any tab under it is.
@MainActor
final class Nest: ObservableObject, Identifiable {
    let id: UUID
    /// Typed while the model was still asked (`unnamed`): the bar goes, the
    /// typed name stays.
    @Published var name: String {
        didSet { if unnamed, name != oldValue { unnamed = false } }
    }
    @Published var customMark: String?
    /// A chosen folder color. Nil keeps the original neutral appearance.
    @Published var color: String?
    /// Hover preview in Customize Folder; never written to the session.
    @Published var previewTint: FolderTint?
    /// Open: its tabs under it. Shut: only the one on screen, if it is one
    /// of them.
    @Published var open: Bool
    /// The words searched, for a folder a search gathered (Research.swift):
    /// such a folder is among today's tabs, not the kept. Nil for one you
    /// made.
    @Published var search: String?
    /// When a search's folder was started, and whether it is still open only
    /// because it was just started: that one shuts by itself once you go to
    /// a tab outside it.
    var born: Date?
    var opened = false

    /// Made by a ⌘-click (Research.gatherLinks) and waiting for the model on
    /// this Mac to name it: its row shows a gray bar where the name goes, as
    /// Dia's does (LinkFolders).
    @Published var unnamed = false
    /// When the model's name came: the row's name shimmers once from then.
    @Published var named: Date?
    /// When it came in behind the bar's dust instead (Rename.swift).
    @Published var renamed: Date?
    /// Made by a ⌘-click or a ⌥⇧-click (Research.swift): its mark is its
    /// pages' site while they are of one, else the emoji its name came with
    /// (LinkFolders.mark).
    var linked = false

    /// The folder of yours it is in, nil at the top of the kept. Never a
    /// search's or one of today's, never one in it (Folders.settle puts
    /// that right whatever made it).
    var parent: Nest?

    /// Where an empty folder at the top of the kept stands, as Arc keeps an
    /// empty folder wherever it was put: just above `before`, a kept tab at
    /// the head of a row or of a folder's run, with `after` and `next` the
    /// heads that were just above and below, so it stays put when that tab
    /// moves away rather than going with it (Folders.stand). Nil: at the
    /// kept's end, above the line, where a new one is made (feedback #384).
    struct Stand: Equatable {
        var before: UUID
        var after: UUID?
        var next: UUID?
    }
    var stand: Stand?

    init(id: UUID = UUID(), name: String, open: Bool = true, search: String? = nil) {
        self.id = id
        self.name = name
        self.open = open
        self.search = search
    }

    /// How deep folders go: a folder in a folder, five down, the last one's
    /// tabs stepped in six marks' widths, which still leaves a title most of
    /// a narrow column.
    nonisolated static let deepest = 5

    /// The folders it is in, from the top down, itself last.
    var chain: [Nest] {
        var out = [self]
        var up = parent
        // A loop in a damaged file stops here.
        while let nest = up, out.count < Nest.deepest * 2, !out.contains(where: { $0 === nest }) {
            out.insert(nest, at: 0)
            up = nest.parent
        }
        return out
    }

    /// 1 at the top of the kept, 2 in a folder, and so on.
    var depth: Int { chain.count }

    /// It, or a folder in it, however deep.
    func within(_ other: Nest) -> Bool { chain.contains { $0 === other } }

    /// A search's folder, among today's tabs.
    var research: Bool { search != nil }

    /// Made of two of today's tabs (SideBar.dwell): among today's as a
    /// search's is, and going as they go, never kept.
    var fleeting = false

    /// An ordinary folder moved below Clear: retains its identity and nesting.
    var ordinaryToday = false

    /// An extension's tab group (ExtensionGroups.swift): one of today's
    /// that stays with a single tab in it.
    var byExtension = false

    /// A meeting's folder (MeetingFolders.swift): its calendar event and
    /// when it ends. It stays with only the call in it until then.
    var meeting: String?
    @Published var meetingEnd: Date?

    /// Kept with one tab: an extension's group, or a meeting's while it is on.
    var staysAlone: Bool { ordinaryToday || byExtension || (meetingEnd.map { $0 > Date() } ?? false) }

    /// A live folder's source: its tabs kept up to date (Live.swift). Nil
    /// for a folder that only holds what you put in it.
    @Published var live: Live?

    /// Among today's tabs rather than the kept: a search's, or one of
    /// today's you made. It shuts and sleeps when left alone, goes whole
    /// when tidied, and goes quietly when down to one tab.
    var today: Bool { ordinaryToday || research || fleeting }

    /// Its folder's id among the others (Folders), an agent's being its
    /// session's.
    var key: String { Nest.key(id) }

    nonisolated static func key(_ id: UUID) -> String { "nest:" + id.uuidString }
    nonisolated static func isKey(_ key: String) -> Bool { key.hasPrefix("nest:") }
}

extension Session {
    /// One of the folders a tab's folder is in, from the top down: all
    /// there is of a folder with no tabs of its own, written on each tab
    /// under it, as a folder is on its own tabs.
    struct Step: Codable, Equatable {
        var id: String
        var name: String
        var open: Bool?
        var mark: String?
        var color: String? = nil
    }
}

extension Nest {
    /// The folders it is in, from the top down, as written beside each tab
    /// in it (Session.Entry.folderPath); nil at the top of the kept.
    var path: [Session.Step]? {
        let up = chain.dropLast()
        guard !up.isEmpty else { return nil }
        return up.map { Session.Step(id: $0.id.uuidString, name: $0.name, open: $0.open, mark: $0.customMark, color: $0.color) }
    }

    /// Put in the folders `path` names, from the top down: each the one
    /// `nests` already has by its id, else made and added there, and given
    /// its name, open or shut and mark when `update` says the path is the
    /// latest word on them (sync), or when just made. A step naming this
    /// folder or one already above in the path is left out.
    func file(in path: [Session.Step]?, nests: inout [String: Nest], update: Bool = false) {
        guard let path, !path.isEmpty else {
            parent = nil
            return
        }
        var above: Nest?
        var seen: [Nest] = [self]
        for step in path.suffix(Nest.deepest - 1) {
            let made = nests[step.id] == nil
            let nest = nests[step.id] ?? Nest(id: UUID(uuidString: step.id) ?? UUID(), name: step.name, open: step.open ?? true)
            guard !seen.contains(where: { $0 === nest }) else { continue }
            if made || update {
                nest.name = step.name
                if let open = step.open { nest.open = open }
                nest.customMark = step.mark
                nest.color = step.color
            }
            nests[step.id] = nest
            nest.parent = above
            seen.append(nest)
            above = nest
        }
        parent = above
    }
}

extension Nest {
    /// Folders brought in from Arc before a folder could be in another came
    /// as one each, the path in the name ("Analitycs › SEO"): each goes in
    /// the folders its name says, one already there by that name or one
    /// made, and is named for the last. Once a space (Browser.loadRow).
    @discardableResult
    static func unflatten(_ tabs: [Tab]) -> Bool {
        let kept = tabs.filter(\.kept)
        let step = "\u{1F}"
        var known: [String: Nest] = [:]
        for tab in kept {
            for nest in tab.nest?.chain ?? [] where !nest.today {
                let key = nest.chain.map(\.name).joined(separator: step)
                if known[key] == nil { known[key] = nest }
            }
        }
        var changed = false
        var seen = Set<ObjectIdentifier>()
        for tab in kept {
            guard let nest = tab.nest, nest.parent == nil, !nest.today, seen.insert(ObjectIdentifier(nest)).inserted else { continue }
            let names = nest.name.components(separatedBy: " \u{203A} ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard names.count > 1, names.allSatisfy({ !$0.isEmpty }) else { continue }
            var above: Nest?
            for depth in 0..<min(names.count - 1, Nest.deepest - 1) {
                let key = names[...depth].joined(separator: step)
                let up = known[key] ?? Nest(name: names[depth], open: nest.open)
                if known[key] == nil {
                    up.parent = above
                    known[key] = up
                }
                above = up
            }
            guard above !== nest else { continue }
            nest.parent = above
            nest.name = names[names.count - 1]
            known[(above?.chain.map(\.name) ?? []).joined(separator: step) + step + nest.name] = nest
            changed = true
        }
        return changed
    }
}

extension Tab {
    /// Whether it can be kept: a page of yours, not a pin, not private, not
    /// an agent's, and somewhere.
    var keepable: Bool { pin == nil && !shy && !bench && !isBlank }

    /// Kept and asleep: nothing to close, so no cross at its end.
    var putDown: Bool { kept && asleep }
}

extension Browser {
    /// The middle button on a tab, as Arc's: it closes as ⌘W does, so a kept
    /// tab awake is put down and keeps its row, and a kept tab already put
    /// down leaves the kept, as its cross takes it (Close and Don't Keep,
    /// ⌘Z brings it back). Before, a second press did nothing (request #415).
    func middleShut(_ tab: Tab) {
        if Self.middleUnkeeps(kept: tab.kept, asleep: tab.asleep) {
            discard([tab], rekept: true)
        } else {
            shut(tab)
        }
    }

    nonisolated static func middleUnkeeps(kept: Bool, asleep: Bool) -> Bool { kept && asleep }
}

extension Browser {
    func toggleKeepTabs() {
        let group = chosen.filter(\.keepable)
        if group.allSatisfy(\.kept) { releaseTabs(group) } else { keepTabs(group) }
    }

    /// Counted, not collected, as `pinnedCount` is.
    var keptCount: Int { tabs.reduce(0) { $0 + ($1.kept ? 1 : 0) } }

    /// Where today's tabs start in the row: after the pins and the kept.
    var keptEnd: Int { pinnedCount + keptCount }

    /// Keep in Sidebar: above the line, at the end of the kept, or of a
    /// folder's tabs (its folders' too: the end of its run), or at `index`
    /// among the kept. A half of a pair brings its other half. One new row
    /// and one write, however many.
    func keepTabs(_ group: [Tab], in nest: Nest? = nil, at index: Int? = nil) {
        if startsArranging { return arranging { keepTabs(group, in: nest, at: index) } }
        // A Blank Window keeps nothing: its tabs are today's alone, as
        // Arc's has no Pin Tab nor New Folder.
        guard !blank else { return }
        var going = group.filter(\.keepable)
        for tab in going { for other in mates(of: tab.id).compactMap({ self.tab(id: $0) }) where other.keepable && !going.contains(where: { $0 === other }) { going.append(other) } }
        guard !going.isEmpty else { return }
        let ids = Set(going.map(\.id))
        going = tabs.filter { ids.contains($0.id) }
        for tab in going {
            tab.kept = true
            tab.nest = nest
        }
        let pins = tabs.filter { $0.pin != nil }
        var kept = tabs.filter { $0.kept && !ids.contains($0.id) }
        // An empty folder standing among the kept: where it stands.
        let end = nest.flatMap { nest in kept.lastIndex { $0.nest?.within(nest) == true }.map { $0 + 1 } ?? folderBook.standIndex(for: nest, in: kept) }
            ?? kept.count
        kept.insert(contentsOf: going, at: min(max(0, index ?? end), kept.count))
        lay(pins + kept + tabs.filter { $0.pin == nil && !$0.kept })
        folderBook.refresh()
        writeSession(now: true)
    }

    /// Don't Keep: under the line again, at the head of today's tabs, in the
    /// order they stood.
    func releaseTabs(_ group: [Tab]) {
        if startsArranging { return arranging { releaseTabs(group) } }
        var going = group.filter(\.kept)
        for tab in going { for other in mates(of: tab.id).compactMap({ self.tab(id: $0) }) where other.kept && !going.contains(where: { $0 === other }) { going.append(other) } }
        guard !going.isEmpty else { return }
        let ids = Set(going.map(\.id))
        going = tabs.filter { ids.contains($0.id) }
        for tab in going {
            tab.kept = false
            tab.nest = nil
        }
        let pins = tabs.filter { $0.pin != nil }
        let kept = tabs.filter(\.kept)
        lay(pins + kept + going + tabs.filter { $0.pin == nil && !$0.kept && !ids.contains($0.id) })
        folderBook.refresh()
        writeSession(now: true)
    }

    /// New Folder with these: kept, together, where the first of them stood
    /// among the kept (or at their end), in a folder that opens with its
    /// name ready to be typed over: in the folder the first of them was in,
    /// as Arc's from tabs picked in a folder is, unless that one is as deep
    /// as folders go, when it is beside it.
    /// `around`: the tab whose folder it goes in and whose place it takes,
    /// a row another was held over; else the first of them.
    func newFolder(with group: [Tab], today: Bool = false, around: Tab? = nil) {
        if startsArranging { return arranging { newFolder(with: group, today: today, around: around) } }
        guard !blank else { return }
        if today { return newTodayFolder(with: group, around: around) }
        let going = group.filter(\.keepable)
        guard !going.isEmpty else { return }
        let nest = Nest(name: "New Folder")
        let first = around ?? tabs.first { tab in going.contains { $0 === tab } }
        if let inside = first?.kept == true ? first?.nest : nil, !inside.today {
            nest.parent = inside.depth < Nest.deepest ? inside : inside.parent
        }
        let kept = tabs.filter(\.kept)
        let at = around.flatMap { tab in kept.firstIndex { $0 === tab } } ?? going.compactMap { tab in kept.firstIndex { $0 === tab } }.min()
        // Out of the folders they were in: the new one is where they stood.
        let before = at.map { at in kept.prefix(at).filter { tab in !going.contains { $0 === tab } }.count }
        keepTabs(going, in: nest, at: before)
        folderBook.naming = nest.id
    }

    /// New Folder with Tabs, from a tab's menu or its key: two or more of
    /// today's stay among today's in a folder of their own; one tab, or any
    /// kept among them, makes a kept folder.
    func newFolder(picked group: [Tab]) {
        let going = group.filter(\.keepable)
        newFolder(with: group, today: going.count > 1 && !going.contains(where: \.kept))
    }

    /// Two of today's tabs, one held over the other: a folder among today's,
    /// where the first of them stood, its name ready. Never kept, so it goes
    /// when today's do (Nest.today).
    private func newTodayFolder(with group: [Tab], around: Tab? = nil) {
        let members = Set(group.flatMap { tab in [tab.id] + mates(of: tab.id) })
        let going = tabs.filter { $0.keepable && members.contains($0.id) }
        guard going.count > 1, let first = around ?? going.first else { return }
        let nest = Nest(name: "New Folder")
        nest.fleeting = true
        var loose = tabs.filter { tab in tab.pin == nil && !going.contains { $0 === tab } }
        // Where the first of them stood among the rest.
        let at = tabs.prefix { $0 !== first }.filter { tab in tab.pin == nil && !going.contains { $0 === tab } }.count
        for tab in going {
            tab.kept = false
            tab.nest = nest
        }
        loose.insert(contentsOf: going, at: min(at, loose.count))
        lay(tabs.filter { $0.pin != nil } + loose)
        folderBook.refresh()
        folderBook.naming = nest.id
        writeSession(now: true)
    }

    /// New Folder, from the line's menu or ⌘T: empty, at the end of the
    /// kept, its name ready to be typed over. It waits there for tabs.
    func newEmptyFolder() {
        guard let nest = folderBook.makeEmpty() else { return }
        folderBook.naming = nest.id
    }

    /// New Folder Inside, from a folder's menu: empty, at the end of that
    /// one's run, which opens if shut, the name ready to be typed over.
    func newFolder(inside parent: Nest) {
        guard parent.depth < Nest.deepest, !parent.today else { return }
        if !parent.open { folderBook.toggle(parent.key) }
        guard let nest = folderBook.makeEmpty(in: parent) else { return }
        folderBook.naming = nest.id
    }

    /// Every tab under a folder: its own and its folders', in the row's order.
    func tabs(in nest: Nest) -> [Tab] {
        tabs.filter { $0.nest?.within(nest) == true }
    }

    /// The folders right in this one, in the row's order, the empty ones last.
    func folders(in nest: Nest) -> [Nest] {
        nests.filter { $0.parent === nest }
    }

    /// How many folders deep it goes, itself one: what it takes into a
    /// folder it is put in.
    func levels(_ nest: Nest) -> Int {
        1 + (folders(in: nest).map { levels($0) }.max() ?? 0)
    }

    /// Whether a folder can go into `parent` (nil: the top of the kept):
    /// never into itself or one in it, never past five deep, never into a
    /// search's or one of today's.
    func canPut(_ nest: Nest, in parent: Nest?) -> Bool {
        guard let parent else { return true }
        return !parent.within(nest) && !parent.today && !nest.today && parent.depth + levels(nest) <= Nest.deepest
    }

    /// Move to Folder for a folder: into one of yours, after its last tab,
    /// or with nil out to the top of the kept, just after the folder it was
    /// in. Its tabs and its folders come with it.
    func file(_ nest: Nest, in parent: Nest?) {
        if startsArranging { return arranging { file(nest, in: parent) } }
        guard parent !== nest.parent, canPut(nest, in: parent) else { return }
        let kept = tabs.filter(\.kept)
        let mine = kept.filter { $0.nest?.within(nest) == true }
        let rest = kept.filter { $0.nest?.within(nest) != true }
        let index: Int
        if let old = nest.parent, parent === old.parent {
            // One step out: just after the folder it was in.
            index = rest.lastIndex { $0.nest?.within(old) == true }.map { $0 + 1 } ?? rest.count
        } else if let parent {
            index = rest.lastIndex { $0.nest?.within(parent) == true }.map { $0 + 1 } ?? folderBook.standIndex(for: parent, in: rest) ?? rest.count
        } else {
            let top = nest.chain.first ?? nest
            index = rest.lastIndex { $0.nest?.within(top) == true }.map { $0 + 1 } ?? rest.count
        }
        nest.parent = parent
        nest.stand = nil
        folderBook.emptyChanged(nest)
        guard !mine.isEmpty else {
            folderBook.refresh()
            writeSession(now: true)
            return
        }
        move(nest, to: index, in: parent)
    }

    /// Move to Folder: into one of yours, after its last tab. A search's
    /// folder, among today's: the tabs stay today's, after its last.
    func file(_ group: [Tab], in nest: Nest) {
        if startsArranging { return arranging { file(group, in: nest) } }
        guard nest.today else { return keepTabs(group, in: nest) }
        let going = group.filter { $0.pin == nil && !$0.bench }
        guard !going.isEmpty else { return }
        let ids = Set(going.map(\.id))
        for tab in going {
            tab.kept = false
            tab.nest = nest
        }
        var loose = tabs.filter { $0.pin == nil && !ids.contains($0.id) }
        let end = loose.lastIndex { $0.nest === nest }.map { $0 + 1 } ?? loose.count
        loose.insert(contentsOf: going, at: end)
        lay(tabs.filter { $0.pin != nil } + loose)
        folderBook.refresh()
        writeSession(now: true)
    }

    /// New Tab in Folder's tab, just made: at the end of the folder's run,
    /// which opens if shut. Its page not in yet, it isn't `keepable`, so it
    /// goes in here rather than by `file`; it needs its address, though.
    func land(_ tab: Tab, in nest: Nest) {
        guard tab.pin == nil, !tab.shy, tab.address != nil, tabs.contains(where: { $0 === tab }),
              nests.contains(where: { $0 === nest }) else { return }
        if !nest.open { folderBook.toggle(nest.key) }
        tab.kept = !nest.today
        tab.nest = nest
        let pins = tabs.filter { $0.pin != nil }
        var rest = tabs.filter { $0.pin == nil && $0 !== tab }
        let run = rest.lastIndex { $0.nest?.within(nest) == true }.map { $0 + 1 }
        // An empty folder of yours stands at the kept's end, or where it
        // was put among them.
        let end = run ?? (nest.today ? rest.count : folderBook.standIndex(for: nest, in: rest.filter(\.kept)) ?? rest.filter(\.kept).count)
        rest.insert(tab, at: min(end, rest.count))
        lay(pins + rest)
        folderBook.refresh()
        writeSession(now: true)
    }

    /// A folder of today's dragged whole up among the kept, as Arc takes a
    /// folder above the line (#440): one of yours from now on, its tabs
    /// kept in it, at `index` among the kept and in `parent` there. Taken
    /// up tab by tab, it was left behind with the last of them.
    func keep(_ nest: Nest, at index: Int, in parent: Nest?) {
        if startsArranging { return arranging { keep(nest, at: index, in: parent) } }
        guard nest.today else { return move(nest, to: index, in: parent) }
        let members = tabs(in: nest)
        let going = members.filter(\.keepable)
        guard !going.isEmpty || folderBook.empties.contains(where: { $0 === nest }) else { return }
        for each in nests where each.within(nest) {
            each.ordinaryToday = false
            each.fleeting = false
            each.search = nil
        }
        nest.ordinaryToday = false
        nest.fleeting = false
        nest.search = nil
        nest.parent = canPut(nest, in: parent) ? parent : nil
        for each in folderBook.empties where each.within(nest) { folderBook.emptyChanged(each) }
        // A row of it that can't be kept, a page still blank, stays one of
        // today's, out of the folder.
        for tab in members where !tab.keepable { tab.nest = nil }
        let homes = going.map { $0.nest }
        keepTabs(going, in: nest, at: index)
        for (tab, home) in zip(going, homes) { tab.nest = home }
        folderBook.refresh()
        writeSession(now: true)
    }

    /// The row with a folder of today's dragged whole to before `tab` among
    /// today's (nil: after the last).
    func order(_ nest: Nest, before tab: Tab.ID?) -> [Tab] {
        let members = tabs.filter { $0.pin == nil && $0.nest?.within(nest) == true }
        var rest = tabs.filter { $0.nest?.within(nest) != true || $0.pin != nil }
        rest.insert(contentsOf: members, at: tab.flatMap { id in rest.firstIndex { $0.id == id } } ?? rest.count)
        return rest
    }

    /// A folder of today's dragged whole to another place among today's.
    func move(_ nest: Nest, before tab: Tab.ID?) {
        if startsArranging { return arranging { move(nest, before: tab) } }
        let members = tabs(in: nest)
        if !nest.today {
            let tree = nests.filter { $0.within(nest) }
            nest.parent = nil
            for each in tree + [nest] { each.ordinaryToday = true; each.stand = nil }
            for member in members { member.kept = false }
            for each in folderBook.empties where each.within(nest) { folderBook.emptyChanged(each) }
        }
        if members.isEmpty {
            nest.stand = tab.map { Nest.Stand(before: $0) }
            folderBook.emptyChanged(nest)
        }
        folderBook.moving.formUnion(members.map(\.id))
        lay(order(nest, before: tab))
        folderBook.refresh()
        writeSession(now: true)
    }

    /// A folder of yours dragged whole: its tabs and its folders' tabs, in
    /// their order, to `index` among the kept that aren't its own, and into
    /// `parent` there (nil: at the top of the kept).
    func move(_ nest: Nest, to index: Int, in parent: Nest?) {
        if startsArranging { return arranging { move(nest, to: index, in: parent) } }
        if parent !== nest.parent, canPut(nest, in: parent) { nest.parent = parent }
        let kept = tabs.filter(\.kept)
        let members = kept.filter { $0.nest?.within(nest) == true }
        guard !members.isEmpty else { return }
        folderBook.moving.formUnion(members.map(\.id))
        var rest = kept.filter { $0.nest?.within(nest) != true }
        rest.insert(contentsOf: members, at: min(max(0, index), rest.count))
        lay(tabs.filter { $0.pin != nil } + rest + tabs.filter { $0.pin == nil && !$0.kept })
        folderBook.refresh()
        writeSession(now: true)
    }

    /// Move Out of Folder: kept still, just after the folder it was in, and
    /// in the folder that one is in, one step out; out of a search's,
    /// today's, just after it.
    func unfile(_ tab: Tab) {
        if startsArranging { return arranging { unfile(tab) } }
        guard let nest = tab.nest else { return }
        tab.nest = nest.today ? nil : nest.parent
        if nest.today {
            var loose = tabs.filter { $0.pin == nil && $0 !== tab }
            let end = loose.lastIndex { $0.nest === nest }.map { $0 + 1 } ?? loose.count
            loose.insert(tab, at: min(end, loose.count))
            lay(tabs.filter { $0.pin != nil } + loose)
            folderBook.refresh()
            writeSession(now: true)
            return
        }
        let kept = tabs.filter(\.kept)
        guard let last = kept.lastIndex(where: { $0.nest?.within(nest) == true }) else {
            folderBook.refresh()
            writeSession(now: true)
            return
        }
        var row = kept.filter { $0 !== tab }
        let end = row.lastIndex { $0.nest?.within(nest) == true }.map { $0 + 1 } ?? min(last, row.count)
        row.insert(tab, at: end)
        lay(tabs.filter { $0.pin != nil } + row + tabs.filter { $0.pin == nil && !$0.kept })
        folderBook.refresh()
        writeSession(now: true)
    }

    /// Remove Folder, Keep Tabs: the folder goes, its tabs and its folders
    /// stay where they are, kept, in the folder it was in.
    func ungroup(_ nest: Nest) {
        if startsArranging { return arranging { ungroup(nest) } }
        let up = nest.parent
        for inner in folders(in: nest) {
            inner.parent = up
            folderBook.emptyChanged(inner)
        }
        for tab in tabs where tab.nest === nest { tab.nest = up }
        folderBook.refresh()
        writeSession(now: true)
    }

    /// Remove Folder and its tabs, or Remove from Folder or Close and Don't
    /// Keep from a tab's menu: no longer kept, and closed as today's tabs
    /// close. With `rekept` (a tab's menu, Remove Folder and its tabs),
    /// ⌘Z or ⌘⇧T brings them back kept, in the folder they were in.
    func discard(_ group: [Tab], rekept: Bool = false) {
        let going = group.filter(\.kept)
        guard !going.isEmpty else { return }
        let kept = tabs.filter(\.kept)
        for tab in going {
            if rekept {
                unkept[tab.id] = .some(tab.nest)
                unkeptAt[tab.id] = kept.firstIndex { $0 === tab }
            }
            tab.kept = false
            tab.nest = nil
        }
        folderBook.refresh()
        close(going)
        // Those that left no ghost (a private page's) leave nothing here.
        unkept = unkept.filter { id, _ in tabs.contains { $0.id == id } }
        unkeptAt = unkeptAt.filter { id, _ in tabs.contains { $0.id == id } }
    }

    /// The folders of yours in this row, in its order, a folder before the
    /// folders in it, the empty ones last.
    var nests: [Nest] {
        var seen: [Nest] = []
        for tab in tabs where tab.kept || tab.nest?.today == true {
            guard let nest = tab.nest else { continue }
            for each in nest.chain where !seen.contains(where: { $0 === each }) { seen.append(each) }
        }
        for empty in folderBook.empties {
            for each in empty.chain where !seen.contains(where: { $0 === each }) { seen.append(each) }
        }
        return seen
    }
}
