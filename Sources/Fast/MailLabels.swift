import Combine
import SwiftUI

// Labels, and the lists beyond the inbox (docs/mail.md, Labels): the
// person's own labels under the column's lists, nested by "/" and closed
// or open as they were left, each with how many of its threads are unread
// (labels.get, asked only for the rows the column shows); a label's list, as
// Starred, Sent, Spam, Trash, Done and All Mail are, read from the store
// first and then asked of Gmail for what is older than the store keeps,
// those threads saying Gmail on their rows. L puts a label on, V moves
// under one, Y takes off the label of the list in front (MailDesk). A
// right-click on a label (MailLabelMenu) reads all its mail, renames it in
// its row, makes one inside it, moves it, makes a split of its senders,
// hides it from the column or deletes it; on the heading, a new label, all
// closed or open, and the hidden ones back.

/// The lists beyond the inbox's as Gmail is asked for them: G then a key's
/// (MailGo.views) and a label's, "label:Work/Clients", by its name.
enum MailViews {
    /// A label's list: "label:" and its whole name.
    static let prefix = "label:"
    /// How many of Gmail's pages of 500 an ask reads on for what isn't
    /// here: the newest are most often here already.
    static let pages = 4

    /// The label a list is of, by its name; nil for another list.
    static func label(_ view: String) -> String? { view.hasPrefix(prefix) ? String(view.dropFirst(prefix.count)) : nil }

    /// Gmail's label behind a list in one store, by id: a label's own, or
    /// Gmail's (STARRED, SENT, SPAM, TRASH); nil for one with none.
    static func labelID(_ view: String, in store: MailStore) -> String? {
        switch view {
        case "starred": return "STARRED"
        case "sent": return "SENT"
        case "spam": return "SPAM"
        case "trash": return "TRASH"
        default: return label(view).flatMap { store.labelID(exactly: $0) }
        }
    }

    /// What Gmail is asked for a list: the list in Gmail's words, before
    /// what the store keeps reaches back to. Nil for one only this Mac
    /// keeps (Muted, Later), for a label the account hasn't, and for any
    /// other list.
    static func query(_ view: String, in store: MailStore) -> MailQuery? {
        if let name = label(view), store.labelID(exactly: name) == nil { return nil }
        return query(view, horizon: MailServerSearch.horizon(store))
    }

    static func query(_ view: String, horizon: Date) -> MailQuery? {
        let words: String
        switch view {
        case "starred": words = "is:starred "
        case "sent": words = "in:sent "
        case "spam": words = "in:spam "
        case "trash": words = "in:trash "
        // Done: someone else's mail out of the inbox, as the store's.
        case "done": words = "-in:inbox -from:me "
        // All Mail: everything but Spam and Trash, as any search of Gmail's.
        case "all": words = ""
        default:
            guard let name = label(view) else { return nil }
            words = "label:\"" + name.replacingOccurrences(of: "\"", with: " ") + "\" "
        }
        return MailQuery.parse(words + "before:" + String(Int(horizon.timeIntervalSince1970)))
    }
}

/// The column's labels: the person's own on the accounts it shows, nested
/// by "/", what is closed, and the unread counts of the rows it shows,
/// read from the stores again whenever one changes.
@MainActor
final class MailLabels: ObservableObject {
    static let shared = MailLabels()

    /// A row of the column's labels.
    struct Row: Identifiable, Equatable {
        /// The label's whole name: its list is "label:" and this.
        let name: String
        /// What the row says: its name after its parent's.
        let leaf: String
        let depth: Int
        /// Labels nested under it, and whether they are shown.
        let parent: Bool
        let open: Bool
        let unread: Int
        var id: String { name }
    }

    /// Every label of the person's on the accounts the column shows, by
    /// name: what L, V and G then L offer. Yab's own (yab/Snoozed) left out.
    @Published private(set) var names: [String] = []
    /// The rows the column shows: no label Gmail's own list hides, none
    /// under a closed one.
    @Published private(set) var rows: [Row] = []
    /// The section closed, and the labels closed over theirs, as left.
    @Published private(set) var folded = Store.settings.bool(forKey: "mail.labels.folded")
    @Published private(set) var closed = Set(Store.settings.stringArray(forKey: "mail.labels.closed") ?? [])
    /// Those Gmail's list hides (Hide from Column), by name: what the
    /// heading's Hidden Labels brings back. Not those inside one of them.
    @Published private(set) var hidden: [String] = []
    /// The label whose name is being typed in its row (Rename…), by its
    /// whole name; the one a label is being made inside (New Label Inside),
    /// "" for one at the top (the heading's New Label). One at a time.
    @Published private(set) var naming: String?
    @Published private(set) var making: String?
    /// The name typed is another label's: said at the field's end.
    @Published private(set) var taken = false
    /// Deleted or hidden while the corner says so with Undo: out of the
    /// column, those inside with them; Gmail hears once the corner has gone.
    private var going = Set<String>()
    private var hiding = Set<String>()
    /// Shown again (Hidden Labels), before Gmail's list says so.
    private var unhiding = Set<String>()
    /// The labels the column lists, open or closed over: where Move To goes.
    private var listedNames: [String] = []
    /// Each account's labels by name: their ids and counts.
    private var byAccount: [String: [String: MailLabel]] = [:]
    /// The same by Gmail's id, for a row's chips (MailLabelChip).
    private var byID: [String: [String: MailLabel]] = [:]
    /// Mail's space is up, its column with it: the rows it shows are the
    /// labels whose counts Gmail is asked, as last told to each account's
    /// sync (a new one, the account added again, is told afresh).
    private var showing = false
    private var told: [ObjectIdentifier: [String]] = [:]
    private var bag: AnyCancellable?

    private init() {
        bag = MailCenter.shared.$changed.dropFirst()
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        // Read once made, after the view that asked for it is drawn.
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    /// Whether the column lists a label: the person's, not Yab's own, and
    /// not one Gmail's list hides.
    nonisolated static func listed(_ label: MailLabel) -> Bool { offered(label) && label.shown != "labelHide" }

    /// Whether L, V and G then L offer it: the person's, not Yab's own.
    nonisolated static func offered(_ label: MailLabel) -> Bool {
        label.user && !label.name.hasPrefix("yab/") && label.name != "yab"
    }

    /// The labels again, from the stores of the accounts shown; a list open
    /// on a label renamed in Gmail follows it, one deleted goes to the inbox.
    func reload() {
        let account = MailList.shared.account
        var by: [String: [String: MailLabel]] = [:]
        for engine in MailCenter.shared.showing(account) {
            var mine: [String: MailLabel] = [:]
            for label in engine.store.labels() where MailLabels.offered(label) { mine[label.name] = label }
            by[engine.account] = mine
        }
        follow(from: byAccount, to: by)
        byAccount = by
        byID = by.mapValues { Dictionary($0.values.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
        let all = Set(by.values.flatMap(\.keys)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if all != names { names = all }
        layout()
    }

    /// The list in front was a label's that changed in Gmail: renamed, it
    /// follows the name; gone, the inbox.
    private func follow(from old: [String: [String: MailLabel]], to new: [String: [String: MailLabel]]) {
        let list = MailList.shared
        guard let name = MailViews.label(list.split), !new.values.contains(where: { $0[name] != nil }) else { return }
        // Not known yet (the store's first list is still to come): stay.
        guard old.values.contains(where: { $0[name] != nil }) else { return }
        for (account, labels) in old {
            guard let id = labels[name]?.id, let renamed = new[account]?.values.first(where: { $0.id == id }) else { continue }
            list.split = MailViews.prefix + renamed.name
            return
        }
        list.split = "needs"
    }

    /// The rows from the names: nested, closed ones' children left out.
    private func layout() {
        var unread: [String: Int] = [:]
        var hidden = Set<String>()
        for labels in byAccount.values {
            for (name, label) in labels {
                unread[name, default: 0] += label.unread ?? 0
                if !MailLabels.listed(label) { hidden.insert(name) }
            }
        }
        hidden.subtract(unhiding)
        let away = hidden.union(hiding).union(going)
        // One hidden or going takes those inside it along, as Gmail's list does.
        let shown = names.filter { name in !away.contains(name) && !away.contains { name.hasPrefix($0 + "/") } }
        listedNames = shown
        let back = names.filter { hidden.contains($0) && !going.contains($0) }
        if back != self.hidden { self.hidden = back }
        let made = MailLabels.tree(shown, closed: closed).map { one in
            Row(name: one.name, leaf: one.leaf, depth: one.depth, parent: one.parent, open: one.open, unread: unread[one.name] ?? 0)
        }
        if made != rows { rows = made }
        tell()
    }

    /// Labels nested by "/": each under the longest name its own begins
    /// with that is a label too ("Work/Clients/Acme" under "Work/Clients",
    /// or "Work" when there is no "Work/Clients"; at the top with its whole
    /// name when none is), each level in the order Gmail sorts names, and
    /// what is under a closed one left out.
    nonisolated static func tree(_ names: [String], closed: Set<String>) -> [(name: String, leaf: String, depth: Int, parent: Bool, open: Bool)] {
        let all = Set(names)
        var parentOf: [String: String] = [:]
        for name in names {
            var cut = name
            while let slash = cut.lastIndex(of: "/") {
                cut = String(cut[..<slash])
                if all.contains(cut) { parentOf[name] = cut; break }
            }
        }
        var children: [String: [String]] = [:]
        for name in names { children[parentOf[name] ?? "", default: []].append(name) }
        let leaf = { (name: String) in parentOf[name].map { String(name.dropFirst($0.count + 1)) } ?? name }
        var out: [(String, String, Int, Bool, Bool)] = []
        func walk(_ under: String, depth: Int) {
            let sorted = (children[under] ?? []).sorted { leaf($0).localizedStandardCompare(leaf($1)) == .orderedAscending }
            for name in sorted {
                let parent = children[name]?.isEmpty == false
                let open = !closed.contains(name)
                out.append((name, leaf(name), depth, parent, open))
                if parent, open { walk(name, depth: depth + 1) }
            }
        }
        walk("", depth: 0)
        return out
    }

    /// A label opened or closed over the labels under it.
    func toggle(_ name: String) {
        if closed.remove(name) == nil { closed.insert(name) }
        Store.settings.set(closed.sorted(), forKey: "mail.labels.closed")
        layout()
    }

    /// Every label with labels inside closed, or every one open.
    func closeAll(_ close: Bool) {
        closed = close ? Set(rows.filter(\.parent).map(\.name)).union(closed) : []
        Store.settings.set(closed.sorted(), forKey: "mail.labels.closed")
        layout()
    }

    /// The whole section closed, or open again.
    func fold() {
        folded.toggle()
        Store.settings.set(folded, forKey: "mail.labels.folded")
        tell()
    }

    /// The names of the labels of these accounts, sorted: what a picker offers.
    func names(accounts: [String]) -> [String] {
        let wanted = Set(accounts)
        return Set(byAccount.filter { wanted.isEmpty || wanted.contains($0.key) }.values.flatMap(\.keys))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// How many threads of a label are unread, over the accounts shown.
    /// A label of the person's on a row, by its account and id: nil for
    /// Yab's own, or one not known here yet.
    func chip(_ id: String, account: String) -> MailLabel? { byID[account]?[id] }

    func unread(_ name: String) -> Int { byAccount.values.reduce(0) { $0 + ($1[name]?.unread ?? 0) } }


    // MARK: - the menu's acts

    /// The accounts shown with a label by this name, each with its own.
    func owners(_ name: String) -> [(engine: MailCenter.Engine, label: MailLabel)] {
        byAccount.keys.sorted().compactMap { account in
            guard let label = byAccount[account]?[name], let engine = MailCenter.shared.engines[account] else { return nil }
            return (engine, label)
        }
    }

    /// The labels inside one, by their whole names, as deep as they go.
    func inside(_ name: String) -> [String] { names.filter { $0.hasPrefix(name + "/") } }

    /// Whether a name is taken by a label of these accounts other than
    /// `but`, case aside, as Gmail compares them.
    private func isTaken(_ name: String, accounts: [String], but: String? = nil) -> Bool {
        let wanted = name.lowercased()
        return accounts.contains { account in
            (byAccount[account] ?? [:]).keys.contains { $0.lowercased() == wanted && $0 != but }
        }
    }

    /// Mark All as Read: every unread thread with the label read here at
    /// once, its count gone; Gmail hears after the hold, as E's does, and is
    /// asked for its unread mail older than this Mac keeps, read there too.
    /// The corner says how many, with Undo.
    func markAllRead(_ name: String) {
        let owners = owners(name)
        var acted: [(engine: MailCenter.Engine, label: MailLabel, acted: MailOps.Acted)] = []
        var count = 0
        for (engine, label) in owners {
            let threads = engine.store.unreadThreads(label: label.id)
            count += max(label.unread ?? 0, threads.count)
            acted.append((engine, label, MailOps.read(threads, after: MailDesk.hold, in: engine.store)))
            engine.store.count(label: label.id, unread: 0, threads: label.threads ?? 0)
            MailCenter.shared.acted(engine.account, after: MailDesk.hold)
        }
        guard count > 0 else { return }
        MailCenter.shared.touch()
        reload()
        // Older than the store keeps: Gmail's own unread with the label,
        // read there by their ids (5 units a page of 500, 50 a thousand read).
        let reading = Reading()
        let asking = Task { @MainActor in
            for (engine, label) in owners {
                var ids: [String] = [], page: String?
                for _ in 0..<10 {
                    guard let got = try? await engine.provider.unread(in: label.id, page: page) else { break }
                    ids += got.ids
                    page = got.next
                    if page == nil { break }
                }
                let known = engine.store.labels(of: ids)
                let unknown = ids.filter { known[$0] == nil }
                guard !reading.undone, !unknown.isEmpty else { continue }
                reading.older.append((engine, MailOps.bulk(.read, messages: unknown, after: MailDesk.hold, in: engine.store), unknown))
                MailCenter.shared.acted(engine.account, after: MailDesk.hold)
            }
        }
        corner(count == 1 ? "1 marked as read" : "\(count.formatted()) marked as read", mark: "envelope.checkmark") { [weak self] in
            reading.undone = true
            asking.cancel()
            for one in acted {
                MailOps.takeBack(one.acted, in: one.engine.store)
                one.engine.store.count(label: one.label.id, unread: one.label.unread ?? 0, threads: one.label.threads ?? 0)
                MailCenter.shared.acted(one.engine.account, after: 0)
            }
            for one in reading.older {
                // Gone to Gmail already: unread again there.
                if one.seqs.filter({ !MailOps.undo($0, in: one.engine.store) }).isEmpty == false {
                    MailOps.bulk(.unread, messages: one.ids, in: one.engine.store)
                }
                MailCenter.shared.acted(one.engine.account, after: 0)
            }
            MailCenter.shared.touch()
            self?.reload()
        } then: {}
    }

    /// Rename…: the label's name typed in its row; New Label Inside, an
    /// empty row under it for the new one's.
    func rename(_ name: String) {
        making = nil
        taken = false
        naming = name
    }

    func make(inside parent: String?) {
        naming = nil
        taken = false
        if folded { fold() }
        if let parent, closed.contains(parent) { toggle(parent) }
        making = parent ?? ""
    }

    /// Typing again in the field: what was taken is said no more.
    func typed() { if taken { taken = false } }

    /// The field in a row done: ↩ (or a click elsewhere) with what was typed,
    /// esc with nil. False when the name is another label's, and the field
    /// stays; with a click elsewhere it goes regardless (`stay` false).
    @discardableResult
    func finish(_ typed: String?, stay: Bool = true) -> Bool {
        let words = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        defer { if !taken || !stay { naming = nil; making = nil; taken = false } }
        guard !words.isEmpty, words.lowercased() != "yab", !words.lowercased().hasPrefix("yab/") else { return true }
        if let name = naming {
            // A "/" files it under another label: the name as typed, whole.
            let parent = name.contains("/") ? String(name[..<name.lastIndex(of: "/")!]) : nil
            let to = words.contains("/") || parent == nil ? words : parent! + "/" + words
            guard to != name else { return true }
            let accounts = owners(name).map(\.engine.account)
            if isTaken(to, accounts: accounts, but: name) {
                taken = true
                return false
            }
            move(name, to: to)
        } else if let parent = making {
            let full = parent.isEmpty ? words : parent + "/" + words
            let accounts = parent.isEmpty ? Array(byAccount.keys) : owners(parent).map(\.engine.account)
            if isTaken(full, accounts: accounts) {
                taken = true
                return false
            }
            create(full, accounts: accounts)
        }
        return true
    }

    /// A label made at Gmail in each of these accounts (labels.create, 5
    /// units), kept at once, its row in its place.
    private func create(_ name: String, accounts: [String]) {
        for account in accounts.sorted() {
            guard let engine = MailCenter.shared.engines[account] else { continue }
            Task { @MainActor in
                do {
                    let made = try await engine.provider.makeLabel(named: name)
                    engine.store.keep(label: made)
                    self.reload()
                } catch {
                    self.trouble("Gmail didn\u{2019}t make \u{201C}\(name)\u{201D}")
                }
            }
        }
    }

    /// Move To, and Rename… with a new name: a label's name changed, those
    /// inside it with it (Work/Clients becoming Projects/Clients, as Gmail's
    /// own page renames them), here at once and then at Gmail
    /// (labels.patch, 5 units each); a list open on it follows. Gmail
    /// refusing puts it back and says so. ⌘Z in mail renames it back.
    func move(_ name: String, to: String, undoable: Bool = true) {
        let owners = owners(name)
        guard !owners.isEmpty, to != name else { return }
        if undoable {
            MailDesk.shared.rememberOther { [weak self] in
                guard let self, !self.owners(to).isEmpty else { return false }
                self.move(to, to: name, undoable: false)
                return true
            }
        }
        let renames = ([name] + inside(name)).map { ($0, to + $0.dropFirst(name.count)) }
        if closed.contains(where: { $0 == name || $0.hasPrefix(name + "/") }) {
            closed = Set(closed.map { one in renames.first { $0.0 == one }?.1 ?? one })
            Store.settings.set(closed.sorted(), forKey: "mail.labels.closed")
        }
        // The new place opened, so the row is seen where it went.
        if let slash = to.lastIndex(of: "/"), closed.contains(String(to[..<slash])) { toggle(String(to[..<slash])) }
        for (engine, _) in owners {
            let mine = byAccount[engine.account] ?? [:]
            let changes = renames.compactMap { old, new in mine[old].map { ($0, new) } }
            for (label, new) in changes { engine.store.keep(label: MailLabel(id: label.id, name: new)) }
            Task { @MainActor in
                do {
                    for (label, new) in changes { _ = try await engine.provider.renameLabel(id: label.id, to: new) }
                } catch {
                    self.trouble("Gmail didn\u{2019}t rename \u{201C}\(name)\u{201D}")
                }
                _ = try? await engine.sync.keepLabels(now: Date(), force: true)
                MailCenter.shared.touch()
                self.reload()
            }
        }
        reload()
    }

    /// Make a Split: the senders of the label's mail here, the most
    /// frequent eight, gathered by a split of the label's name and tag, as
    /// the offer's Make the Split makes one; it opens.
    func makeSplit(_ name: String) {
        var senders: [String: Int] = [:]
        for (engine, label) in owners(name) {
            let me = engine.account.lowercased()
            for thread in engine.store.threads(label: label.id, limit: 300) {
                guard let who = thread.people.first?.address.lowercased(), who != me else { continue }
                senders[who, default: 0] += 1
            }
        }
        let leaf = name.split(separator: "/").last.map(String.init) ?? name
        guard !senders.isEmpty else {
            corner("No mail in \u{201C}\(leaf)\u{201D} on this Mac", mark: "tag")
            return
        }
        let top = senders.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(8).map(\.key)
        let list = MailList.shared
        let made = list.keepSplit(title: leaf, q: MailRule.line(top.map { MailRule(kind: "from", value: $0) }), icon: "tag", mode: .also)
        MailDesk.shared.browser?.showMailPage()
        if list.searched { MailSearch.shared.clear() }
        list.split = made
    }

    /// Hide from Column: out of the column now, those inside with it, the
    /// corner saying so with Undo; Gmail's list hides it too once the corner
    /// has gone (labelListVisibility). Hidden Labels on the heading shows
    /// it again.
    func hide(_ name: String) {
        hiding.insert(name)
        layout()
        corner("\u{201C}\(leaf(name))\u{201D} hidden", mark: "eye.slash") { [weak self] in
            self?.hiding.remove(name)
            self?.layout()
        } then: { [weak self] in
            self?.tell(name, shown: "labelHide") { self?.hiding.remove(name) }
        }
    }

    /// Hidden Labels: one back in the column at once, and in Gmail's list.
    func show(_ name: String) {
        if hiding.remove(name) != nil { layout(); return }
        unhiding.insert(name)
        layout()
        tell(name, shown: "labelShow") { [weak self] in self?.unhiding.remove(name) }
    }

    private func tell(_ name: String, shown: String, after: @escaping () -> Void) {
        let owners = owners(name)
        Task { @MainActor in
            for (engine, label) in owners {
                if (try? await engine.provider.showLabel(id: label.id, shown)) == nil {
                    self.trouble(shown == "labelHide" ? "Gmail didn\u{2019}t hide \u{201C}\(name)\u{201D}" : "Gmail didn\u{2019}t show \u{201C}\(name)\u{201D}")
                }
                _ = try? await engine.sync.keepLabels(now: Date(), force: true)
            }
            after()
            MailCenter.shared.touch()
            self.reload()
        }
    }

    /// Delete: out of the column now with those inside it, a list open on
    /// one of them back to Needs you, the corner saying so with Undo; Gmail
    /// deletes them once the corner has gone (labels.delete, 5 units each),
    /// their mail kept, with its other labels.
    func delete(_ name: String) {
        let all = [name] + inside(name)
        going.insert(name)
        let list = MailList.shared
        if let open = MailViews.label(list.split), all.contains(open) { list.split = "needs" }
        layout()
        let n = all.count - 1
        corner(n == 0 ? "Deleted \u{201C}\(leaf(name))\u{201D}" : "Deleted \u{201C}\(leaf(name))\u{201D} and \(n) inside", mark: "trash") { [weak self] in
            self?.going.remove(name)
            self?.layout()
        } then: { [weak self] in
            guard let self else { return }
            let owners = self.owners(name)
            Task { @MainActor in
                for (engine, _) in owners {
                    let mine = self.byAccount[engine.account] ?? [:]
                    for one in all.reversed() {
                        guard let label = mine[one] else { continue }
                        if (try? await engine.provider.deleteLabel(id: label.id)) == nil {
                            self.trouble("Gmail didn\u{2019}t delete \u{201C}\(one)\u{201D}")
                        }
                    }
                    _ = try? await engine.sync.keepLabels(now: Date(), force: true)
                }
                self.going.remove(name)
                MailCenter.shared.touch()
                self.reload()
            }
        }
    }

    private func leaf(_ name: String) -> String { name.split(separator: "/").last.map(String.init) ?? name }

    /// Something Gmail refused, said in the corner.
    private func trouble(_ words: String) {
        MailDesk.shared.browser?.toaster.pop(words, mark: "exclamationmark.triangle")
    }

    /// The corner saying what was done, with Undo; `then` once the corner
    /// has gone without it: when it closes, or says something else and its
    /// Undo is gone with that. Without a window, after the hold.
    private func corner(_ words: String, mark: String, undo: (() -> Void)? = nil, then: @escaping () -> Void = {}) {
        guard let toaster = MailDesk.shared.browser?.toaster else {
            DispatchQueue.main.asyncAfter(deadline: .now() + MailDesk.hold, execute: then)
            return
        }
        guard let undo else {
            toaster.pop(words, mark: mark)
            return
        }
        let undone = Reading()
        var token: UUID?
        toaster.pop(words, mark: mark, undo: {
            undone.undone = true
            if let token { MailDesk.shared.forgetUndo { $0.token == token } }
            undo()
        })
        let said = toaster.words
        // ⌘Z in mail takes it back too, while the corner still says it:
        // after, Gmail has heard (`then`).
        token = MailDesk.shared.rememberOther { [weak toaster] in
            guard let toaster, !undone.undone, toaster.shown, toaster.words == said else { return false }
            toaster.undone()
            return true
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard !undone.undone else { return timer.invalidate() }
                guard !toaster.shown || toaster.words != said else { return }
                timer.invalidate()
                then()
            }
        }
    }

    // MARK: - the menus

    /// What a right-click on a label offers (MailLabelMenu), as lines the
    /// bench reads and presses too. With two accounts showing a label by
    /// its name, every line acts on both and a heading names them.
    func lines(_ name: String) -> [MailLabelLine] {
        guard let row = rows.first(where: { $0.name == name }) else { return [] }
        let accounts = owners(name).map(\.engine.account)
        let n = accounts.count
        let within = inside(name)
        var out: [MailLabelLine] = []
        if n > 1 { out.append(.header(ListFormatter.englishString(byJoining: accounts))) }
        out.append(MailLabelLine("Mark All as Read", mark: "yab.inbox.check", enabled: row.unread > 0) { [weak self] in self?.markAllRead(name) })
        if row.parent {
            out.append(MailLabelLine(row.open ? "Close Labels Inside" : "Open Labels Inside") { [weak self] in self?.toggle(name) })
        }
        out.append(.divider)
        out.append(MailLabelLine(n > 1 ? "Rename in \(n) Accounts\u{2026}" : "Rename\u{2026}", mark: "pencil") { [weak self] in self?.rename(name) })
        out.append(MailLabelLine("New Label Inside", mark: "folder.badge.plus") { [weak self] in self?.make(inside: name) })
        out.append(MailLabelLine("Move To", mark: "yab.folder.right", sub: moves(name)))
        out.append(.divider)
        out.append(MailLabelLine("Make a Split", mark: "yab.inbox.plus") { [weak self] in self?.makeSplit(name) })
        out.append(MailLabelLine("Hide from Column", mark: "eye.slash") { [weak self] in self?.hide(name) })
        out.append(.divider)
        let delete = within.isEmpty ? (n > 1 ? "Delete from \(n) Accounts" : "Delete Label")
            : "Delete \u{201C}\(row.leaf)\u{201D} and \(within.count) Inside"
        out.append(MailLabelLine(delete, mark: "trash") { [weak self] in self?.delete(name) })
        return out
    }

    /// Move To's lines: every other label shown, nested as in the column,
    /// none inside this one or the one it is in; and out of that one, for a
    /// label inside another.
    private func moves(_ name: String) -> [MailLabelLine] {
        let parent = name.lastIndex(of: "/").map { String(name[..<$0]) }
        let leaf = self.leaf(name)
        let all = MailLabels.tree(listedNames, closed: [])
        var out = all.filter { $0.name != name && !$0.name.hasPrefix(name + "/") && $0.name != parent }.map { other in
            MailLabelLine(String(repeating: "\u{2003}", count: other.depth) + other.leaf,
                          enabled: !isTaken(other.name + "/" + leaf, accounts: Array(byAccount.keys))) { [weak self] in
                self?.move(name, to: other.name + "/" + leaf)
            }
        }
        if let parent {
            if !out.isEmpty { out.append(.divider) }
            let up = parent.lastIndex(of: "/").map { String(parent[..<$0]) + "/" + leaf } ?? leaf
            out.append(MailLabelLine("Move Out of \u{201C}\(self.leaf(parent))\u{201D}", enabled: !isTaken(up, accounts: Array(byAccount.keys))) { [weak self] in
                self?.move(name, to: up)
            })
        }
        return out
    }

    /// What a right-click on the heading offers: a new label, every label
    /// with labels inside closed or open, and those hidden back.
    var headingLines: [MailLabelLine] {
        var out = [MailLabelLine("New Label", mark: "plus") { [weak self] in self?.make(inside: nil) }]
        let parents = rows.filter(\.parent)
        if !parents.isEmpty {
            let open = parents.allSatisfy(\.open)
            out.append(MailLabelLine(open ? "Close All Labels" : "Open All Labels") { [weak self] in self?.closeAll(open) })
        }
        if !hidden.isEmpty {
            out.append(.divider)
            out.append(MailLabelLine("Hidden Labels", mark: "eye", sub: hidden.map { name in
                MailLabelLine(name) { [weak self] in self?.show(name) }
            }))
        }
        return out
    }

    // MARK: - counts

    /// Mail's space came up, its column with it: the counts of the rows it
    /// shows are asked from now on.
    func came() {
        showing = true
        reload()
    }

    /// Mail's space gone: no counts asked until the column is back.
    func gone() {
        showing = false
        tell()
    }

    /// Each account's sync told which labels the column shows (none while
    /// it is away or its labels are closed), in the column's order, when
    /// that changed; those not counted lately are asked now
    /// (MailSync.countLabels), the rest as their mail changes, and the
    /// rows read again when a count came out otherwise.
    private func tell() {
        let names = showing && !folded ? rows.map(\.name) : []
        for engine in MailCenter.shared.engines.values {
            let ids = names.compactMap { byAccount[engine.account]?[$0]?.id }
            let sync = engine.sync
            guard told[ObjectIdentifier(sync)] != ids else { continue }
            told[ObjectIdentifier(sync)] = ids
            Task { [weak self] in
                await sync.set(shownLabels: ids)
                guard !ids.isEmpty, (try? await sync.countLabels(now: Date())) == true else { return }
                self?.reload()
            }
        }
    }
}

/// The column's labels, under its lists: a heading that closes the section,
/// a row each, nested, a chevron on one with labels under it, in the type
/// of the lists above it. Scrolls with the whole column; each row draws its
/// own plate when chosen, as the lists' rows do.
/// Drawn again only when its labels or the label chosen changed, not with
/// every change of the column (`equatable()`): going from one of the
/// inbox's lists to another doesn't reach in here; and then only the rows
/// that changed, the two plates moving.
struct MailLabelRows: View, Equatable {
    @ObservedObject var labels: MailLabels
    /// The label whose list is in front, by its name; nil for another list,
    /// or a search over it.
    let chosen: String?
    @Environment(\.tone) private var tone

    static func == (a: Self, b: Self) -> Bool { a.chosen == b.chosen }

    var body: some View {
        // With every label hidden the heading stays, its menu bringing them back.
        if !labels.rows.isEmpty || !labels.hidden.isEmpty || labels.making == "" {
            VStack(alignment: .leading, spacing: SideBar.gap) {
                Button { labels.fold() } label: {
                    HStack(spacing: 4) {
                        Text("Labels")
                        Symbol("chevron.right", size: 8, weight: .semibold)
                            .rotationEffect(.degrees(labels.folded ? 0 : 90))
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted(on: tone))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.top, 16)
                .padding(.bottom, 2)
                .accessibilityLabel(labels.folded ? "Labels, closed" : "Labels")
                .contextMenu { MailLabelMenu(name: nil) }
                if !labels.folded {
                    // Scrolled with the whole column (MailColumn), its rows
                    // made as they come.
                    LazyVStack(alignment: .leading, spacing: SideBar.gap) { each }
                }
            }
        }
    }

    @ViewBuilder
    private var each: some View {
        // The heading's New Label: its field at the top until it is named.
        if labels.making == "" { MailLabelFieldRow(text: "", depth: 0, taken: labels.taken) }
        ForEach(labels.rows) { row in
            let naming = labels.naming == row.name
            MailLabelRow(row: row, chosen: chosen == row.name, naming: naming, taken: naming && labels.taken,
                         toggle: { MailLabels.shared.toggle(row.name) }) {
                MailDesk.shared.browser?.showMailPage()
                if MailList.shared.split == MailViews.prefix + row.name { MailDesk.shared.back() }
                if MailList.shared.searched { MailSearch.shared.clear() }
                MailList.shared.split = MailViews.prefix + row.name
            }
            .equatable()
            // New Label Inside: the field under it, a level in.
            if labels.making == row.name { MailLabelFieldRow(text: "", depth: row.depth + 1, taken: labels.taken) }
        }
    }
}

/// A label's row: the tag, its name after its parent's, set in a step per
/// level, a chevron after the name when labels are under it, and how many
/// unread at its end, where the lists' counts are. The chevron opens and
/// closes; anywhere else chooses the label's list. Its two actions are the
/// same for the same label, so the row is what it shows.
private struct MailLabelRow: View, Equatable {
    let row: MailLabels.Row
    let chosen: Bool
    /// Its name being typed (Rename…), and the name typed another label's.
    let naming: Bool
    let taken: Bool
    let toggle: () -> Void
    let choose: () -> Void
    /// The lists' size above it (MailColumnRow), not a smaller one of its own.
    @Environment(\.tabTitleSize) private var titleSize
    @Environment(\.tone) private var tone
    @State private var hovering = false

    static func == (a: Self, b: Self) -> Bool { a.row == b.row && a.chosen == b.chosen && a.naming == b.naming && a.taken == b.taken }

    var body: some View {
        if naming {
            MailLabelFieldRow(text: row.leaf, depth: row.depth, taken: taken)
        } else {
            plain
        }
    }

    private var plain: some View {
        HStack(spacing: 0) {
            Button(action: choose) {
                HStack(spacing: SideBar.markGap) {
                    Symbol("tag", size: SideBar.mark - 3)
                        .foregroundStyle(chosen ? Palette.ink : Palette.muted(on: tone))
                        .frame(width: SideBar.mark, height: SideBar.mark)
                        .padding(.leading, CGFloat(row.depth) * 12)
                    Text(row.leaf)
                        .font(.system(size: titleSize))
                        .foregroundStyle(chosen ? Palette.ink : Palette.strong(on: tone).opacity(0.88))
                        .lineLimit(1)
                }
                .padding(.leading, SideBar.inner)
                .frame(height: SideBar.row)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            if row.parent {
                Button(action: toggle) {
                    Symbol("chevron.right", size: 8, weight: .semibold)
                        .rotationEffect(.degrees(row.open ? 90 : 0))
                        .foregroundStyle(Palette.muted(on: tone))
                        .frame(width: 20, height: SideBar.row)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyTip(row.open ? "Hide the labels under it" : "Show the labels under it")
            }
            Button(action: choose) {
                HStack(spacing: 0) {
                    Spacer(minLength: 4)
                    if row.unread > 0 {
                        Text("\(row.unread)")
                            .font(.system(size: titleSize - 0.5).monospacedDigit())
                            .foregroundStyle(Palette.muted(on: tone))
                            .lineLimit(1)
                    }
                }
                .padding(.trailing, SideBar.endInset) // design: a tab row's own ends
                .frame(height: SideBar.row)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background {
            RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                .fill(chosen ? Palette.wash(on: tone) : hovering ? Palette.hover(on: tone) : .clear)
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.unread > 0 ? "\(row.name), \(row.unread) unread" : row.name)
        .contextMenu { MailLabelMenu(name: row.name) }
    }
}

/// A label's row with its name being typed: the tag where the row has it,
/// the field where the name was, on the wash a folder being named wears
/// (NestRow); "Taken" at its end when the name is another label's.
private struct MailLabelFieldRow: View {
    let text: String
    let depth: Int
    let taken: Bool
    @Environment(\.tabTitleSize) private var titleSize
    @Environment(\.tone) private var tone

    var body: some View {
        HStack(spacing: SideBar.markGap) {
            Symbol("tag", size: SideBar.mark - 3)
                .foregroundStyle(Palette.ink)
                .frame(width: SideBar.mark, height: SideBar.mark)
                .padding(.leading, CGFloat(depth) * 12)
            MailLabelNameField(text: text)
                .frame(height: titleSize + 4)
            if taken {
                Text("Taken")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize()
            }
        }
        .padding(.leading, SideBar.inner)
        .padding(.trailing, SideBar.endInset) // design: a tab row's own ends
        .frame(height: SideBar.row)
        .background(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous).fill(Palette.wash(on: tone)))
        .accessibilityLabel(text.isEmpty ? "New label name" : "Name of \(text)")
    }
}

/// The foot of a list beyond the inbox's once all this Mac holds of it is
/// in: said quietly while Gmail looks for its older mail, and, when Gmail
/// found more than came, the way to it (J past the last row does the same).
struct MailViewFoot: View {
    @ObservedObject var desk: MailDesk
    @ObservedObject var list: MailList
    @ObservedObject private var server = MailServerSearch.shared

    var body: some View {
        let searching = desk.who != nil || !desk.query.trimmingCharacters(in: .whitespaces).isEmpty
        if MailGo.isView(list.split), !searching, !desk.rows.isEmpty, desk.rows.count >= desk.total {
            let gmail = server.view(list.split, account: list.account)
            Group {
                if gmail.asking {
                    Text("Looking in Gmail for older mail")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.faint)
                } else if gmail.more {
                    Button { desk.older() } label: { Text("Show Older Mail from Gmail") }
                        .buttonStyle(.yab(.quiet, .small))
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

/// What an act with Undo in the corner (MailLabels.corner) keeps while the
/// corner is up: Undo pressed, and Mark All as Read's mail older than this
/// Mac keeps, read at Gmail by its ids, to be taken back with the rest.
@MainActor
private final class Reading {
    var undone = false
    var older: [(engine: MailCenter.Engine, seqs: [Int64], ids: [String])] = []
}

/// A line of a label's menu or of the heading's (MailLabels.lines): what
/// MailLabelMenu draws, and the bench reads and presses.
struct MailLabelLine {
    enum Kind { case act, divider, header }
    var kind = Kind.act
    var title = ""
    var mark: String?
    var enabled = true
    var sub: [MailLabelLine] = []
    var run: (() -> Void)?

    init(_ title: String, mark: String? = nil, enabled: Bool = true, sub: [MailLabelLine] = [], run: (() -> Void)? = nil) {
        self.title = title
        self.mark = mark
        self.enabled = enabled
        self.sub = sub
        self.run = run
    }

    private init(kind: Kind, title: String = "") {
        self.kind = kind
        self.title = title
    }

    static var divider: MailLabelLine { MailLabelLine(kind: .divider) }
    static func header(_ words: String) -> MailLabelLine { MailLabelLine(kind: .header, title: words) }

    /// A line by its title, a submenu's as "Move To/Hiring": for the bench.
    static func find(_ path: String, in lines: [MailLabelLine]) -> MailLabelLine? {
        let clean = { (title: String) in title.trimmingCharacters(in: CharacterSet(charactersIn: "\u{2003}")) }
        // A title with a slash in it, a hidden label's whole name, as it is.
        if let whole = lines.first(where: { $0.kind == .act && clean($0.title) == path }) { return whole }
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return nil }
        guard let line = lines.first(where: { $0.kind == .act && clean($0.title) == first }) else { return nil }
        return parts.count > 1 ? find(parts[1], in: line.sub) : line
    }
}

/// A right-click on a label, or on the heading (`name` nil): the lines as
/// the column stands when it opens, in the app's menu look, marks as the
/// tab menu wears them.
struct MailLabelMenu: View {
    let name: String?
    @ObservedObject private var labels = MailLabels.shared

    var body: some View {
        let lines = name.map(labels.lines) ?? labels.headingLines
        if let first = lines.first, first.kind == .header {
            Section(first.title) { MailLabelLines(lines: Array(lines.dropFirst())) }
        } else {
            MailLabelLines(lines: lines)
        }
    }
}

struct MailLabelLines: View {
    let lines: [MailLabelLine]

    var body: some View {
        ForEach(lines.indices, id: \.self) { index in
            let line = lines[index]
            switch line.kind {
            case .divider: Divider()
            case .header: Text(line.title)
            case .act:
                if line.sub.isEmpty {
                    Button(line.title, mark: line.mark) { line.run?() }
                        .disabled(!line.enabled)
                } else {
                    Menu(line.title, mark: line.mark) { MailLabelLines(lines: line.sub) }
                }
            }
        }
    }
}

/// A label's name typed in its row, as a folder's is (NestNameField):
/// everything picked to type over, ↩ or a click elsewhere keeps what was
/// typed, esc what it was. A name another label has keeps the field on ↩.
struct MailLabelNameField: NSViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.stopWatching()
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: context.environment.tabTitleSize)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.isAutomaticTextCompletionEnabled = false
        field.placeholderString = text.isEmpty ? "Name" : nil
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let font = NSFont.systemFont(ofSize: context.environment.tabTitleSize)
        if field.font != font {
            field.font = font
            field.currentEditor()?.font = font
        }
        field.appearance = context.environment.tone?.appearance
        let coordinator = context.coordinator
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            guard field.window != nil else { return }
            field.window?.makeFirstResponder(field)
            coordinator.watch(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.11)),
                .foregroundColor: Palette.NS.ink,
            ]
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var claimed = false
        private var done = false
        private var clicks: Any?

        func watch(_ field: NSTextField) {
            guard clicks == nil else { return }
            clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak field] event in
                guard let self, let field, let window = field.window else { return event }
                if event.window !== window || !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                    self.finish(field.stringValue, stay: false)
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        func stopWatching() {
            if let clicks { NSEvent.removeMonitor(clicks) }
            clicks = nil
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                finish(control.stringValue, stay: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(nil, stay: false)
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            finish((note.object as? NSTextField)?.stringValue, stay: false)
        }

        func controlTextDidChange(_ note: Notification) {
            MainActor.assumeIsolated { MailLabels.shared.typed() }
        }

        private func finish(_ typed: String?, stay: Bool) {
            guard !done else { return }
            done = true
            let kept = MainActor.assumeIsolated { MailLabels.shared.finish(typed, stay: stay) }
            if kept {
                stopWatching()
                if stay { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
            } else {
                // Taken: the field stays, to be typed again.
                done = false
            }
        }
    }
}
