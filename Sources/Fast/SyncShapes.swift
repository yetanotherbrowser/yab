import CryptoKit
import Foundation
import SyncKit

// What Yab's own files look like as records that sync (PLAN-sync.md, phase
// 0), and back. Pure: a file's contents in, a collection's records out, so a
// mirror can tell the journal what changed and write in what came from
// elsewhere without either side knowing the other's shape. The records'
// fields are SyncKit's (Shapes.swift), the iPhone's too: this file only
// turns Yab's own types into those values and back.
//
// Collections:
// - space: one per space, its look and its place among the spaces.
// - tab: every written tab of every space, by its own id (Session.Entry.id);
//   `parent` is its space. A closed tab stays closed (removalWins).
// - folder: a folder of yours, a search's or one of today's, by its Nest id.
// - pair: two tabs side by side, by both their ids.
// - bookmark: each bookmark and folder of bookmarks; `parent` is its folder
//   or "root".
// - setting: one per key of the allowed list.

enum SyncShapes {
    static let space = SyncCollection.space, tab = SyncCollection.tab, folder = SyncCollection.folder, pair = SyncCollection.pair
    static let bookmark = SyncCollection.bookmark, setting = SyncCollection.setting, file = SyncCollection.file, icon = SyncCollection.icon
    static let routine = SyncCollection.routine, memory = SyncCollection.memory, visit = SyncCollection.visit, answer = SyncCollection.answer
    static let root = SyncCollection.root, project = SyncCollection.project

    /// Every collection's merge rules, the iPhone's the same.
    static func register() { SyncCollection.register() }

    // MARK: History

    /// How far back history syncs: the last two weeks, what the field and
    /// the history list need on another device; older stays on each Mac.
    static let historyDays: TimeInterval = 14 * 86_400

    /// Places been to lately, by their key. Counts stay on each Mac: a
    /// count that went round the devices would come back added to itself.
    /// A sign-in's step kept before History left them out stays too.
    static func visits(_ list: [Visit]) -> Collection {
        RecordShapes.visits(list.filter { !(URL(string: $0.url).map(History.signInStep) ?? false) }.map { visit in
            SyncVisit(id: visit.key, url: visit.url, title: visit.title, last: visit.last.timeIntervalSince1970, typed: (visit.typed ?? 0) > 0)
        })
    }

    static func visits(from records: [SyncKit.Record]) -> [(url: URL, title: String, last: Date, typed: Bool)] {
        records.compactMap(SyncVisit.init).compactMap { visit in
            guard let url = URL(string: visit.url) else { return nil }
            return (url, visit.title, Date(timeIntervalSince1970: visit.last), visit.typed)
        }
    }

    /// This Mac's places and those it deleted by hand, told to the journal
    /// (SyncCenter's flush). Deleted by hand: marked first, then removed, so
    /// the other devices tell it from a place that only left the two weeks.
    static func tellVisits(_ list: [Visit], cuts: [String: Date], into journal: Journal) throws {
        try reconcileVisits(journal, visits(list), cuts: cuts)
    }

    /// Which records a flush may remove for being missing from `now`. A Yab
    /// from before ports were part of the key names a server's page without
    /// its port (`localhost/blog` for localhost:3000/blog), so its record's
    /// id is never in `now`. Removed, that device would write it back at its
    /// next flush, and again after each. Such a record stays while this Mac
    /// has its place, under the key with the port, and goes when the place does.
    static func removable(keeping now: Collection) -> (SyncKit.Record) -> Bool {
        { record in
            guard let place = SyncVisit.key(of: record), place != record.id else { return true }
            return now[place] == nil
        }
    }

    /// The places deleted here by hand (History.cuts) that sync holds,
    /// marked with when, for the flush to tell before it removes them: a
    /// removal alone also means a place left the two weeks or this Mac
    /// stopped syncing history, which the other devices must not follow.
    /// Only places no longer in `now`. One already removed (another Mac
    /// stopped syncing history) is cut too, or the others keep it. A
    /// server's page is also cut under the key an older Yab gives it,
    /// without the port, when that record is of the same page, so the
    /// older device lets it go too.
    static func cut(_ cuts: [String: Date], in journal: Journal, keeping now: Collection) -> Collection {
        var out: Collection = [:]
        for (key, at) in cuts where now[key] == nil {
            for id in [key, SyncVisit.portless(key)].compactMap({ $0 }) {
                guard let record = journal.record(.init(collection: visit, id: id)),
                      id == key || SyncVisit.key(of: record) == key else { continue }
                // A removed one keeps what it said, so it is never up without
                // its address between the mark and the removal.
                var fields = record.alive() ? record.visible : record.fields.filter { !$0.value.isNull }
                fields["cut"] = .number(at.timeIntervalSince1970.rounded(.down))
                out[id] = fields
            }
        }
        return out
    }

    /// This Mac's places told to the journal. Deleted by hand: marked
    /// first, then removed, so the other devices tell it from a place that
    /// only left the two weeks. Three-way (Journal.reconcile's `shown`):
    /// a place goes up when it changed here, not because this Mac's copy
    /// differs from the record. Two Macs that last searched different
    /// things under one key (google.com/search) each sent theirs back on
    /// every flush, forever.
    /// A place another Mac removed without deleting it (it left the two
    /// weeks there, or history sync was turned off there) is still this
    /// Mac's, and goes up again whole. One deleted by hand stays gone unless
    /// this Mac has been there since, as History.dropSynced keeps it.
    static func reconcileVisits(_ journal: Journal, _ now: Collection, cuts: [String: Date]) throws {
        let revive: (SyncKit.Record, [String: Value]) -> Bool = { record, fields in
            guard let cut = cutVisits(from: [record]).first else { return true }
            return (fields["last"]?.number ?? 0) > cut.at.timeIntervalSince1970 + 1
        }
        let ours = removable(keeping: now)
        // An older Yab's record of a server's page, keyed without its port,
        // was never in these files: it goes when the place it is of, which
        // they held under the key with the port, leaves them.
        let held = journal.shown(visit)
        let olderOf: (SyncKit.Record) -> Bool = { record in
            guard let place = SyncVisit.key(of: record), place != record.id else { return false }
            return held[place] != nil && now[place] == nil
        }
        let cut = cut(cuts, in: journal, keeping: now)
        if !cut.isEmpty { try journal.reconcile(visit, now.merging(cut) { mine, _ in mine }, within: ours, shown: true, orphaned: olderOf, revive: revive) }
        try journal.reconcile(visit, now, within: ours, shown: true, orphaned: olderOf, revive: revive)
    }

    /// Places deleted by hand on another device, by key and when: a removed
    /// record whose last change before the removal was its cut. One cut
    /// once, visited again since and gone out of the two weeks, is not.
    /// Keyed by the record's address, so a cut from an older Yab, whose ids
    /// leave out a server's port, takes the place with the port here.
    static func cutVisits(from records: [SyncKit.Record]) -> [(key: String, at: Date)] {
        records.compactMap { record in
            guard !record.alive(), let at = record.fields["cut"]?.number, let stamp = record.stamps["cut"],
                  !record.stamps.contains(where: { $0.key != "cut" && $0.value > stamp }) else { return nil }
            return (SyncVisit.key(of: record) ?? record.id, Date(timeIntervalSince1970: at))
        }
    }

    // MARK: Form answers

    /// What forms were answered with (FormAnswers), one record a question
    /// on a site: two Macs answering forms on the same day both keep
    /// theirs, as a whole file, the newer one winning, would not.
    static func answers(_ said: [FormAnswers.Said]) -> Collection {
        var out: Collection = [:]
        for one in said {
            out[one.id] = [
                "question": .string(one.question),
                "answer": .string(one.answer),
                "site": .string(one.site),
                "at": .number(one.at.timeIntervalSince1970.rounded(.down)),
                "fresh": one.fresh == true ? .bool(true) : .null,
            ]
        }
        return out
    }

    /// The answers the records make, oldest first, and those kept here that
    /// sync hasn't heard of yet, which go up with the next read.
    static func answers(from records: [SyncKit.Record], local: [FormAnswers.Said]) -> [FormAnswers.Said] {
        let known = Set(records.map(\.id))
        let synced = records.filter { $0.alive() }.compactMap { record -> FormAnswers.Said? in
            guard let question = record["question"]?.string, let answer = record["answer"]?.string,
                  let site = record["site"]?.string, let at = record["at"]?.number else { return nil }
            return FormAnswers.Said(question: question, answer: answer, site: site, at: Date(timeIntervalSince1970: at),
                                    fresh: record["fresh"]?.bool == true ? true : nil)
        }
        return (synced + local.filter { !known.contains($0.id) }).sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    // MARK: Memory

    /// What agents keep about you (Memory.swift): each page whole, the
    /// newest copy winning; the diary (episodic/) by entry, so what two Macs
    /// noted on the same day adds up instead of one day's file beating the
    /// other's. A page or an entry written from mail stays on its Mac
    /// (Memory.fromMail, docs/casa.md).
    static func memory(in folder: URL) -> Collection {
        var out: Collection = [:]
        // Both sides without symlinks: /var is /private/var, and a path
        // cut at the wrong length names a page that isn't there.
        let root = folder.resolvingSymlinksInPath().path + "/"
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in walker where url.pathExtension == "md" {
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(root) else { continue }
            let path = String(full.dropFirst(root.count))
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.utf8.count < 48_000 else { continue }
            if path.hasPrefix("episodic/") {
                for entry in entries(text) where !Memory.fromMail(entry) {
                    out[path + "#" + digest(entry)] = ["day": .string(path), "text": .string(entry)]
                }
            } else if !Memory.fromMail(text) {
                out[path] = ["text": .string(text)]
            }
        }
        return out
    }

    /// A day's entries: each "## " heading and what follows it.
    static func entries(_ text: String) -> [String] {
        var out: [String] = [], current: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if !current.isEmpty { out.append(current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) }
        return out.filter { !$0.isEmpty }
    }

    /// The files the records make, by path: a page as it is, a day as its
    /// title and its entries in the order of their headings (their times).
    static func memoryFiles(from records: [SyncKit.Record]) -> [String: String] {
        var out: [String: String] = [:]
        var days: [String: [String]] = [:]
        for record in records where record.alive() {
            if let day = record["day"]?.string, let text = record["text"]?.string {
                days[day, default: []].append(text)
            } else if !record.id.contains("#"), let text = record["text"]?.string {
                out[record.id] = text
            }
        }
        for (day, texts) in days {
            let date = (day as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
            out[day] = "# \(date)\n\n" + texts.sorted().joined(separator: "\n\n") + "\n"
        }
        return out
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Routines

    /// What each routine is, and which Mac runs it; how its runs went
    /// (last, what it said, its chat, the mail it has done) stays on the
    /// Mac that ran them. One from before sync is run by the Mac that sends
    /// it first. A plugin's routines (`boost:`) don't go: each Mac makes
    /// them from the plugins it has.
    static func routines(_ list: [Routine], device: String) -> Collection {
        var out: Collection = [:]
        for var routine in list where !routine.id.hasPrefix(pluginRoutines) {
            if routine.runsOn == nil { routine.runsOn = device }
            routine.last = nil; routine.said = nil; routine.session = nil
            routine.chat = nil; routine.found = nil; routine.ended = nil
            routine.mailSince = nil; routine.mailDone = nil
            guard case .object(var fields)? = try? Value(encoding: routine) else { continue }
            fields["id"] = nil
            out[routine.id] = fields
        }
        return out
    }

    static let pluginRoutines = "boost:"

    /// The routines here told to the journal. A plugin's routine records
    /// an older Yab still writes are left as they are: that Yab runs them
    /// from those records.
    static func reconcileRoutines(_ journal: Journal, _ list: [Routine], device: String) throws {
        try journal.reconcile(routine, routines(list, device: device), within: { !$0.id.hasPrefix(pluginRoutines) })
    }

    static func routines(from records: [SyncKit.Record]) -> [Routine] {
        records.filter { $0.alive() && !$0.id.hasPrefix(pluginRoutines) }.sorted { $0.id < $1.id }.compactMap { record in
            var fields = record.visible
            fields["id"] = .string(record.id)
            return try? Value.object(fields).decode(Routine.self)
        }
    }

    // MARK: Projects

    /// Every project of chats, whole (SyncProject); its memory and files
    /// stay here.
    static func projects(_ list: [Project]) -> Collection {
        var out: Collection = [:]
        for one in list {
            out[one.id] = SyncProject(id: one.id, name: one.name, emoji: one.emoji, tint: one.tint, instructions: one.instructions,
                                      memoryOn: one.memoryOn, pinned: one.pinned, archived: one.archived == true, order: one.order,
                                      created: one.created.timeIntervalSince1970, updated: one.updated.timeIntervalSince1970).fields
        }
        return out
    }

    static func projects(from records: [SyncKit.Record]) -> [SyncProject] {
        records.compactMap(SyncProject.init)
    }

    // MARK: Files

    /// Small files of yours kept whole, the newest copy winning: what you
    /// set up in Search, Quick Actions and Commands, what you hid on sites,
    /// short names, and what forms know about you. Paths under Store.folder.
    /// Form answers are records of their own (`answers`). Mail's snippets
    /// stay on each Mac: one can be a mail saved as it is.
    static let files = [
        "scopes.json", "quick-actions.json", "commands.json", "hidden.json", "short-names.json",
        "profile.json", "know.json", "form-labels.json",
    ]

    /// Each file that is there, as JSON. One too big for a record stays here.
    static func files(in folder: URL) -> Collection {
        var out: Collection = [:]
        for path in files {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(path)), data.count < 48_000,
                  var json = try? JSONDecoder().decode(Value.self, from: data) else { continue }
            // The profile's `edited` is a set: a file written before it was
            // sorted says the same in another order.
            if path == "profile.json", case .object(var profile) = json, let edited = profile["edited"]?.array {
                profile["edited"] = .array(edited.sorted { ($0.string ?? "") < ($1.string ?? "") })
                json = .object(profile)
            }
            out[path] = ["json": json]
        }
        return out
    }

    /// The profile a `profile.json` record carries, as its file reads.
    static func profile(from record: SyncKit.Record) -> Profile? {
        guard let json = record["json"], let data = try? JSONEncoder().encode(json) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Profile.self, from: data)
    }

    /// Pictures you gave tabs and folders (custom-icons/), each one whole.
    static func icons(in folder: URL) -> Collection {
        let dir = folder.appendingPathComponent("custom-icons")
        var out: Collection = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)), data.count < 48_000 else { continue }
            out[name] = ["data": .string(data.base64EncodedString())]
        }
        return out
    }

    typealias Collection = RecordShapes.Collection

    // MARK: Spaces

    static func spaces(_ list: [Space], orders previous: [String: String]) -> Collection {
        RecordShapes.spaces(list.map { space in
            SyncSpace(id: space.id.uuidString, name: space.name, icon: space.icon, ownSignIns: space.ownSignIns,
                      paint: space.paint.flatMap { try? Value(encoding: $0) }.flatMap(SyncPaint.init), origin: space.origin,
                      search: space.search, searchCustom: space.searchCustom, iconChoice: space.iconChoice, iconChoiceID: space.iconChoiceID, signInWith: space.signInWith?.uuidString)
        }, orders: previous)
    }

    static func spaces(from records: [SyncKit.Record]) -> [Space] {
        RecordShapes.spaces(from: records).compactMap { space in
            guard let id = UUID(uuidString: space.id) else { return nil }
            return Space(id: id, name: space.name, icon: space.icon, ownSignIns: space.ownSignIns,
                         paint: try? space.paint?.raw.decode(SpacePaint.self), origin: space.origin,
                         signInWith: space.signInWith.flatMap(UUID.init(uuidString:)),
                         search: space.search, searchCustom: space.searchCustom, iconChoice: space.iconChoice, iconChoiceID: space.iconChoiceID)
        }
    }

    // MARK: Rows

    /// Every space's row as records of three collections. `orders` are the
    /// tabs' and folders' keys as the journal has them, so only what moved
    /// gets a new one. A tab of today's is `device`'s, unless `owner` says
    /// whose it already was (SyncShapes.owners): this Mac's own, or nobody's
    /// for one from before Today was each device's.
    static func rows(_ rows: [UUID: Session.Shape], orders previous: [String: String], device: String? = nil,
                     owner: [String: String?] = [:]) -> (tabs: Collection, folders: Collection, pairs: Collection) {
        var tabs: Collection = [:], folders: Collection = [:], pairs: Collection = [:]
        for (space, shape) in rows {
            let parent = space.uuidString
            let written = shape.tabs.compactMap { entry in entry.id.map { (entry, $0) } }
            let orders = Order.assign(written.map(\.1), previous: previous)
            for (entry, id) in written {
                // `seen` goes to five minutes (SyncTab.round): the tab on
                // screen is written as seen now on every save, and Tidy
                // counts in hours. A pin's or a kept tab's home is
                // PinnedHome.swift's.
                tabs[id] = SyncTab(id: id, space: parent, order: orders[id], url: entry.url, title: entry.title, pin: entry.pin,
                                   name: entry.name, seen: entry.seen, kept: entry.kept == true, folder: entry.folder,
                                   live: entry.live.flatMap { try? Value(encoding: $0) }, customMark: entry.customMark,
                                   depth: entry.depth, home: entry.home, homeTitle: entry.homeTitle,
                                   device: owner[id] ?? device).fields
                // A folder is written on each of its tabs; it is one record,
                // standing where its first tab stands. The folders it is in,
                // written on its tabs as a path, are records too, each saying
                // the folder it is in (`folder`), even those no tab is right
                // in.
                let path = entry.folderPath ?? []
                for (at, step) in path.enumerated() where folders[step.id] == nil {
                    folders[step.id] = SyncFolder(id: step.id, space: parent, order: orders[id], name: step.name, open: step.open,
                                                  today: entry.folderToday, ordinaryToday: entry.folderOrdinaryToday, customMark: step.mark, color: step.color, folder: at > 0 ? path[at - 1].id : nil).fields
                }
                if let folder = entry.folder, folders[folder] == nil {
                    folders[folder] = SyncFolder(id: folder, space: parent, order: orders[id], name: entry.folderName,
                                                 open: entry.folderOpen, search: entry.folderSearch, today: entry.folderToday, ordinaryToday: entry.folderOrdinaryToday, linked: entry.folderLinked,
                                                 live: entry.folderLive.flatMap { try? Value(encoding: $0) },
                                                 customMark: entry.folderMark, color: entry.folderColor, folder: path.last?.id).fields
                }
            }
            for pair in shape.pairs ?? [] {
                guard shape.tabs.indices.contains(pair.first), shape.tabs.indices.contains(pair.second),
                      let a = shape.tabs[pair.first].id, let b = shape.tabs[pair.second].id
                else { continue }
                let value = SyncPair(first: a, second: b, space: parent, share: pair.share)
                pairs[value.id] = value.fields
            }
        }
        return (tabs, folders, pairs)
    }

    /// Tabs or folders as `rows` wrote them, with the links their rows
    /// couldn't draw put back: one whose record (`had`) names a folder this
    /// journal has never held (`held`) and that the row wrote in no folder
    /// still names it. A row shows a folder only once its record is here
    /// (`row`); a folder known and removed lets its tabs go.
    static func keepingLinks(_ out: Collection, had: [SyncKit.Record], held: Set<String>) -> Collection {
        var out = out
        for record in had {
            guard var fields = out[record.id], fields["folder"]?.string == nil,
                  let link = record["folder"]?.string, !held.contains(link) else { continue }
            fields["folder"] = .string(link)
            out[record.id] = fields
        }
        return out
    }

    /// Today's tabs another device opened without saying whose they are
    /// (an iPhone or a Mac from before `device`), by id: the device that
    /// opened each, as this Mac first heard of it (SyncCenter.receive). Kept
    /// on this Mac only; a tab that was here before stays this Mac's to show.
    static let markedKey = "sync.todayOwners"
    static var marked: [String: String] {
        get { Store.settings.dictionary(forKey: markedKey) as? [String: String] ?? [:] }
        set { newValue.isEmpty ? Store.settings.removeObject(forKey: markedKey) : Store.settings.set(newValue, forKey: markedKey) }
    }

    /// A tab's record with the device it is open on: its own `device`, or
    /// the one `marked` says opened it.
    static func owned(_ record: SyncKit.Record, marked: [String: String]) -> SyncTab? {
        guard var tab = SyncTab(record) else { return nil }
        if tab.device == nil, tab.list == .today, let device = marked[record.id] { tab.device = device }
        return tab
    }

    /// New tabs of today's coming in without `device`, opened by another
    /// device: that device's from now on (Today is each device's own). Only
    /// records this journal hasn't held yet; returns `marked` with them,
    /// and without tabs gone or kept.
    static func mark(_ items: [SyncKit.Record], in journal: Journal, device: String, marked: [String: String]) -> [String: String] {
        var out = marked
        for record in items where record.collection == tab {
            guard let incoming = SyncTab(record) else { out[record.id] = nil; continue }
            if incoming.list != .today || incoming.device != nil { out[record.id] = nil; continue }
            guard out[record.id] == nil, journal.record(record.key) == nil,
                  let opener = record.stamps["url"]?.device, opener != device else { continue }
            out[record.id] = opener
        }
        return out
    }

    /// Whose each tab of today's in the journal already is: its device, or
    /// nil for one from before. A tab the Mac keeps keeps its owner while it
    /// stays one of today's; one it just put back from the kept is its own.
    static func owners(_ tabs: [SyncKit.Record], marked: [String: String] = [:]) -> [String: String?] {
        var out: [String: String?] = [:]
        for tab in tabs.compactMap({ owned($0, marked: marked) }) where tab.list == .today { out[tab.id] = .some(tab.device) }
        return out
    }

    /// A tab of today's open on another device: not this Mac's to show,
    /// write or remove.
    static func elsewhere(_ record: SyncKit.Record, device: String, marked: [String: String] = [:]) -> Bool {
        guard let tab = owned(record, marked: marked) else { return false }
        return !tab.shown(to: device, mac: true)
    }

    /// One space's row from the records: pins, then the kept, then
    /// today's, each in order; folders back on their tabs; pairs by where
    /// their tabs now stand. What is this device's own, which tab is in
    /// front and how often each was looked at here, comes from `here`, the
    /// row as this device last wrote it.
    /// `device`: only what this Mac shows, never another device's tabs of
    /// today (SyncTab.shown).
    static func row(_ space: UUID, tabs: [SyncKit.Record], folders: [SyncKit.Record], pairs: [SyncKit.Record], here: Session.Shape,
                    device: String? = nil, marked: [String: String] = [:]) -> Session.Shape {
        let local = Dictionary(here.tabs.compactMap { entry in entry.id.map { ($0, entry) } }, uniquingKeysWith: { a, _ in a })
        // Left with none in front, on a tab gone since, or on a shared pin
        // (below zero), it stays so.
        let front = here.front
        let active = front.flatMap { here.tabs.indices.contains($0) ? here.tabs[$0].id : nil }
        let parent = space.uuidString
        let mine = tabs.compactMap { owned($0, marked: marked) }.filter { $0.space == parent && $0.shown(to: device, mac: true) }
            .sorted(by: RecordShapes.placed)
        let pins = mine.filter { $0.list == .pinned }
        let kept = mine.filter { $0.list == .kept }
        let today = mine.filter { $0.list == .today }
        // Any space's folder: a tab names the folder it is in, wherever
        // that folder's record says it stands.
        let byFolder = Dictionary(folders.compactMap(SyncFolder.init).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The folders a folder is in, from the top down, by each record's
        // `folder`; a loop or a folder gone ends it.
        func path(of folder: SyncFolder?) -> [Session.Step]? {
            var steps: [Session.Step] = []
            var seen: Set<String> = [folder?.id ?? ""]
            var up = folder?.folder.flatMap { byFolder[$0] }
            while let one = up, seen.insert(one.id).inserted, steps.count < Nest.deepest - 1 {
                steps.insert(Session.Step(id: one.id, name: one.name ?? "Folder", open: one.open, mark: one.customMark, color: one.color), at: 0)
                up = one.folder.flatMap { byFolder[$0] }
            }
            return steps.isEmpty ? nil : steps
        }
        let ordered = pins + kept + today
        let entries = ordered.map { tab -> Session.Entry in
            let folder = tab.folder.flatMap { byFolder[$0] }
            return Session.Entry(
                url: tab.url,
                title: tab.title,
                pin: tab.pin,
                name: tab.name,
                seen: tab.seen,
                kept: tab.kept ? true : nil,
                folder: folder?.id,
                folderName: folder?.name,
                folderOpen: folder?.open,
                folderPath: path(of: folder),
                folderSearch: folder?.search,
                folderToday: folder?.today,
                folderOrdinaryToday: folder?.ordinaryToday,
                folderLinked: folder?.linked,
                folderLive: try? folder?.live?.decode(Live.self),
                live: try? tab.live?.decode(LiveMark.self),
                customMark: tab.customMark,
                folderMark: folder?.customMark,
                folderColor: folder?.color,
                visits: local[tab.id]?.visits,
                id: tab.id,
                depth: tab.depth,
                home: tab.home,
                homeTitle: tab.homeTitle)
        }
        let at = Dictionary(ordered.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var used = Set<Int>()
        let kept2 = pairs.compactMap(SyncPair.init).filter { $0.space == parent }.sorted { $0.id < $1.id }.compactMap { pair -> Session.Pair? in
            guard let a = at[pair.first], let b = at[pair.second], !used.contains(a), !used.contains(b) else { return nil }
            used.formUnion([a, b])
            return Session.Pair(first: a, second: b, share: pair.share)
        }
        let placed = front.flatMap { $0 < 0 ? $0 : active.flatMap { at[$0] } }
        return Session.Shape(tabs: entries, front: placed, pairs: kept2.isEmpty ? nil : kept2)
    }

    // MARK: Bookmarks

    static func bookmarks(_ tree: [Bookmark], orders previous: [String: String]) -> Collection {
        func value(_ mark: Bookmark) -> SyncBookmark {
            SyncBookmark(id: mark.id.uuidString, title: mark.title, url: mark.url, added: mark.added?.timeIntervalSince1970,
                         children: mark.children?.map(value), space: mark.space?.uuidString, importKey: mark.importKey)
        }
        return RecordShapes.bookmarks(tree.map(value), orders: previous)
    }

    /// The tree from the records, put right first: a bookmark whose folder
    /// went elsewhere goes to the top level, a loop is cut (Tree.repair).
    static func bookmarks(from records: [SyncKit.Record]) -> [Bookmark] {
        func mark(_ value: SyncBookmark) -> Bookmark? {
            guard let id = UUID(uuidString: value.id) else { return nil }
            return Bookmark(id: id, title: value.title, url: value.url, children: value.children?.compactMap(mark),
                            added: value.added.map(Date.init(timeIntervalSince1970:)), space: value.space.flatMap(UUID.init(uuidString:)), importKey: value.importKey)
        }
        return RecordShapes.bookmarks(from: records).compactMap(mark)
    }

    // MARK: Settings

    /// The settings that are yours rather than this Mac's, by key, and by
    /// prefix for those kept per site or per extension. A key not here
    /// stays on this Mac: new keys are local until someone adds them. Mail's
    /// splits, lists and their order stay too: their rules name senders,
    /// subjects and Gmail's labels (docs/casa.md, Sync).
    static let settingKeys: Set<String> = [
        "look", "backdrop", "sidebar", "tabs.glyph", "sidebar.density", "addressbar", "addressbar.full-url", "peek.address",
        "bookmarks.bar", "pages.zoom", "pages.fonts", "pages.dark", "pages.darkLook", "appearance.appIcon",
        "tabs.sleep", "tabs.awake", "tabs.tidy", "tabs.researchFolders", "tabs.linkFolders", "tabs.folderEmoji", "tabs.optShiftFolders", "tabs.meetingFolders", "spaces", "pins.everySpace", "peek", "links.small", "links.small.key",
        "split.rule", "quit.warn", "player.shown", "float.leave", "float.away",
        "links.routes", "links.routes.kept", "links.routes.declined", "shortcuts",
        "search.engine", "search.custom", "scopes.off", "scopes.keywords", "scopes.templates", "scopes.learn", "scopes.recent",
        "shield", "devSites", "extensions.private",
        "passwords.save", "passwords.fill", "passwords.never", "autofill.save", "autofill.fill", "autofill.forms", "autofill.drafts",
        // The passkeys switch by its own key (Preferences.passkeysKey):
        // "passkeys" also carried the false of Macs that can't do them.
        "passkeys.offer", "codes.mail",
        "agents.asking", "agents.askOpens", "agents.messages", "agents.forget", "agents.exceptions",
        "tidy.titles", "folders.names", "tidy.downloads",
        "mail.motion", "mail.signature.replies",
        "mail.badge", "mail.undo", "mail.sense", "mail.time.shift", "downloads.ask", "uploads.finder",
        "field.favorites", "field.firstRow", "field.under", "field.under.off", "field.sections", "field.sections.off", "field.frequentReach",
        "field.page.order", "field.page.hiddenKinds", "field.page.base",
        "field.page.kept", "stamp.info", "stamp.since", "activity.person", "gift.firstEdition.receipt",
        "invite.charm.left", "invite.charm.right",
    ]
    static let settingPrefixes = [shortcutPrefix, "zoom.", "dark.", "capture.", "location.", "notifications.", "open.", "shield.paused",
                                  "extensions.access.", "extensions.settings.", "extensions.keys.", "extensions.commands.", "mail.slots.", "mail.zero.", "models."]
    /// Switching spaces writes the window's paint into these defaults.
    /// Only a space's paint record is shared, never which one is worn here.
    /// Per-window selections (window.<id>.space) are outside the allowlist too.
    static let localSpaceKeys: Set<String> = [
        "space.current", "backdrop.swatch", "backdrop.color", "backdrop.colors", "backdrop.transparency",
        "backdrop.grain", "backdrop.grain.amount", "backdrop.shift", "backdrop.site-tint",
        "backdrop.drawings", "backdrop.drawings.strength", "backdrop.mode", "backdrop.glass",
    ]
    static let settingExceptions: Set<String> = localSpaceKeys.union(["models.recent"])
    static let charmPaletteKeys: Set<String> = ["invite.charm.left", "invite.charm.right"]

    static func syncs(_ key: String) -> Bool {
        guard !settingExceptions.contains(key) else { return false }
        return AppIconGrants.icon(for: key) != nil || settingKeys.contains(key) || settingPrefixes.contains { key.hasPrefix($0) }
    }

    /// An extension's own: where it may reach, what it set, its keys. They
    /// go with Settings › Sync, Extensions and plugins.
    static func extensionSetting(_ key: String) -> Bool {
        ["extensions.access.", "extensions.settings.", "extensions.keys.", "extensions.commands."].contains { key.hasPrefix($0) }
    }

    /// The settings here told to the journal. An extension's own go with
    /// Settings › Sync, Extensions and plugins: while it is off they are
    /// neither sent nor removed.
    /// A Mac that has split its keys (below) gives up a key's record when
    /// the key goes back to its own; one that hasn't yet only adds its keys,
    /// so the first flush after the update removes none of another Mac's.
    /// Icon grants only add: an award earned elsewhere is never removed
    /// because this Mac has no local invite or receipt for it.
    /// Old window-paint records stay untouched: removing one would reset
    /// the defaults on an older Mac that still takes those records.
    /// Returns the keys as the journal has them once a Mac first splits.
    @discardableResult
    static func reconcileSettings(_ journal: Journal, _ defaults: [String: Any], addons: Bool) throws -> [String: String]? {
        let split = defaults[shortcutsSplit] as? Bool == true
        let localCharm = AppIconGrants.ownsLocalCharm(defaults)
        try journal.reconcile(setting, settings(defaults, addons: addons), within: {
            !localSpaceKeys.contains($0.id) && AppIconGrants.icon(for: $0.id) == nil &&
                (localCharm || !charmPaletteKeys.contains($0.id)) &&
                (addons || !extensionSetting($0.id)) && (split || !$0.id.hasPrefix(shortcutPrefix))
        })
        return split ? nil : shortcuts(from: journal.living(setting))
    }

    static func settings(_ defaults: [String: Any], addons: Bool = true) -> Collection {
        var out: Collection = [:]
        let localCharm = AppIconGrants.ownsLocalCharm(defaults)
        for (key, value) in defaults where syncs(key) && AppIconGrants.icon(for: key) == nil &&
            (localCharm || !charmPaletteKeys.contains(key)) && (addons || !extensionSetting(key)) {
            if let value = plist(value) { out[key] = ["value": value] }
        }
        for icon in AppIconGrants.owned(defaults) { out[icon.grantKey] = ["value": .bool(true)] }
        for (action, key) in defaults[shortcutsKey] as? [String: String] ?? [:] {
            out[shortcutPrefix + action] = ["value": .string(key)]
        }
        return out
    }

    // MARK: Keyboard shortcuts

    /// The keys chosen in Settings › Shortcuts go one record an action, so
    /// a key changed on one Mac and another on a second both stay. The
    /// whole dictionary still goes up as `shortcuts` for a Yab from before,
    /// and is taken only until this Mac has split.
    static let shortcutsKey = "shortcuts"
    static let shortcutPrefix = "shortcut."
    /// Kept on this Mac only: its keys have gone up one an action.
    static let shortcutsSplit = "sync.shortcuts.split"

    static func shortcuts(from records: [SyncKit.Record]) -> [String: String] {
        var out: [String: String] = [:]
        for record in records where record.alive() && record.id.hasPrefix(shortcutPrefix) {
            if let key = record["value"]?.string { out[String(record.id.dropFirst(shortcutPrefix.count))] = key }
        }
        return out
    }

    /// A property list value as a field: data as base64 under "$data", so
    /// it comes back data and not a string.
    static func plist(_ any: Any) -> Value? {
        switch any {
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: return .string(s)
        case let d as Data: return .object(["$data": .string(d.base64EncodedString())])
        case let date as Date: return .object(["$date": .number(date.timeIntervalSince1970)])
        case let a as [Any]: return .array(a.compactMap(plist))
        case let o as [String: Any]: return .object(o.compactMapValues(plist))
        default: return nil
        }
    }

    static func plist(_ value: Value) -> Any? {
        switch value {
        case .null: return nil
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) as Any : n
        case .string(let s): return s
        case .array(let a): return a.compactMap(plist)
        case .object(let o):
            if o.count == 1, let base64 = o["$data"]?.string { return Data(base64Encoded: base64) }
            if o.count == 1, let seconds = o["$date"]?.number { return Date(timeIntervalSince1970: seconds) }
            return o.compactMapValues(plist)
        }
    }
}
