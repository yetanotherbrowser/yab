import AppKit
import MailCore
import UniformTypeIdentifiers

// The box's places beside Clipboard History and Emoji: Downloads, Passwords,
// Autofill (you, your cards and addresses), History, Bookmarks
// (BookmarkPlace.swift), the chats kept with agents, and Files when a page
// asks. Each is a list with the chosen one
// beside it (PlaceView), made of the same rows, with the same keys:
//
//   ↩   the best thing to do with it here: open, fill, paste
//   ⌘↩  copy its main value, never anything else
//   ⌘O  go where it came from: the page, the site
//   ⇧⌘C copy what else it has: a user name, a path, a line
//   ⌃X  forget it
//   ⌘E  write it, ⌘N a new one (PlaceEdit.swift)
//   ⌘K  everything, with a search of its own
//
// They are all there is: the pages yab://downloads, yab://passwords,
// yab://autofill, yab://history and yab://bookmarks they grew out of are
// gone, and what the pages did, the places do.

/// One row of a place.
struct PlaceItem: Identifiable {
    let id: String
    /// The heading it is listed under: "Today", "This Site", "Cards".
    let section: String
    let title: String
    /// Under the title: where it came from, whose it is.
    var source = ""
    var tile: PlaceTile
    /// What the words are looked for in, when more than the title and the
    /// line under it: a card's nickname, an address's every line.
    var search = ""
    /// Gone, or run out: listed, but quieter.
    var faded = false
    /// A word after the title that needs a look: "leaked", "reused",
    /// "weak", "expired"; `alarm` in the warning's color.
    var tag: String?
    var alarm = false
    /// Something new there, not seen yet: the tag in the accent.
    var fresh = false
    let what: PlaceThing
}

/// What a place's row is.
enum PlaceThing {
    case kept(Keep)
    case file(URL)
    /// A file mail carried, or one you gave a site (FileShelf).
    case shelf(ShelfFile)
    case fetch(Hoard.Fetch)
    case login(Vault.Entry)
    case card(SavedCard)
    case address(StreetAddress)
    case visit(url: URL, title: String, key: String, at: Date, count: Int)
    /// A day's thread, in History's By Thread (docs/day-threads.md).
    case thread(DayThread)
    /// A site kept, or a folder of them.
    case bookmark(Bookmark)
    /// A chat with an agent, by its id (Chats).
    case chat(String)
    /// A project of chats, by its id (Projects).
    case project(String)
    /// A routine, by its id (Routines).
    case routine(String)
    /// A snippet, by its id (MailSnippets).
    case snippet(String)
    /// You: the profile forms are filled from (Profile).
    case profile
    /// A card or an address being written for the first time (PlaceEdit).
    case draft
    /// Autofill with nothing kept yet, while other browsers on this Mac
    /// have cards or addresses: all of them brought in at once.
    case bring
    /// A Store listing, by its id (StoreCatalog).
    case boost(String)
    /// The Store's own last rows: "build" with an agent, or "ask" the board.
    case storeMake(String)
    /// One of Now's rows, by its id (Hints).
    case hint(String)
    /// A subscription, an order or a receipt, by its id (Purchases).
    case purchase(String)
}

/// What a row wears at its head.
enum PlaceTile {
    /// A site's icon, or its first letter.
    case site(String)
    /// A kept page's icon (Bookmarks): the one it last wore, its site's for
    /// a page never open here, its site's letter until one is fetched.
    case page(URL)
    /// Three sites' icons, one over another: a thread's (History's By Thread).
    case stack([String])
    /// The Mac's own icon for a file.
    case file(String)
    /// One of the app's marks on its tile.
    case symbol(String)
    /// A download still coming, with how far it has got.
    case fetch(Hoard.Fetch)
    /// A card's network, as the list under a card's box draws it (PayMark).
    case pay(String)
    /// A Now row's own mark, by its id (HintMark).
    case hint(String)
    /// A project's circle, by its id (ProjectCircle).
    case project(String)
}

/// What the box keeps while a place is open, so it isn't read again on
/// every keystroke: the keychain's list of logins and cards (never a
/// secret), and History's rows, which come back from the diary later.
struct PlaceStock {
    var logins: [Vault.Entry] = []
    var codes: Set<String> = []
    var cards: [SavedCard] = []
    var addresses: [StreetAddress] = []
    var visits: [PlaceItem] = []
    var files: [PlaceItem] = []
    /// The rows of what Files looks in now, before any search: Recent's,
    /// or a folder's.
    var fileRecent: [PlaceItem] = []
    /// The folder Files is kept to (FileFolders); nil for Recent.
    var fileFolder: URL?
    /// Each folder's rows as read this opening, by its path ("" Recent).
    var fileLooks: [String: [PlaceItem]] = [:]
    /// Which question History's rows answer, so an old answer arriving
    /// after a newer question is dropped.
    var asked = 0
    /// The browsers on this Mac with something to bring in, for an empty
    /// place; nil until counted.
    var sources: [PlaceSource]?
    /// Autofill's browsers with cards or addresses, and how many of each,
    /// for the row that brings them all in; nil until counted.
    var wallets: [(source: Chromium.Source, cards: Int, addresses: Int)]?
    /// Logins the other browsers have that aren't here, for a search that
    /// found nothing; read once a minute at most.
    var elsewhere: [(login: Login, from: String)]?
    var elsewhereAt: Date?
    /// Only the read started for this opening may replace its results.
    var elsewhereReadID: UUID?
    /// The browser being brought in from now.
    var bringing: String?
    /// What can be said of each password without showing it: how many
    /// other logins share it, which are easy to guess, which were seen in
    /// a breach and how often.
    var shared: [String: Int] = [:]
    var weak: Set<String> = []
    var leaked: [String: Int] = [:]
    /// An immutable read identity, never reused when this stock is reset.
    var passwordAnalysis: UUID?
    /// Where ↩ takes a page History found by what it said: to those words.
    var jumps: [String: URL] = [:]
    /// History has no older rows than those listed.
    var ended = false
    /// Which password each login shares, to name the others that have it.
    var groups: [String: String] = [:]
    /// You, and how many answers to forms are kept.
    var profile = Profile()
    var answered = 0
    /// History kept to one thread's pages (Show Its Pages), and the thread
    /// By Thread opens on (Open in History from Memory › Days).
    var threadPages: DayThread?
    var threadChosen: Int64?
    /// The list kept to one site (History, Downloads), and the sites gone
    /// to most, for the filter's menu.
    var site: String?
    var sites: [(host: String, count: Int)] = []
    /// The folder Bookmarks shows; nil for the top of the list.
    var folder: Bookmark.ID?
    /// Bookmarks shows Recently Added instead: every site whose day is
    /// known, newest first, whatever folder it is in.
    var recent = false
    /// Bring In More…: the ways in, shown where the list was.
    var more = false
    var safari: SafariStep?
    var trouble: PlaceTrouble?
    /// How far bringing passwords in has got: kept, of how many.
    var keeping: (Int, Int)?
    /// Bumped when what is kept was read again, so the rows are made again.
    var version = 0
    /// What Mail is open over: the page's thread, commands or times.
    var mail: MailFieldContext?
}

/// A completed read belongs to the stock that asked for it. Check its
/// identity before replacing rows, keeping everything else as it is now.
struct PasswordElsewhereReply {
    let readID: UUID
    let logins: [(login: Login, from: String)]

    func applying(to stock: PlaceStock) -> PlaceStock? {
        guard stock.elsewhereReadID == readID else { return nil }
        var current = stock
        current.elsewhere = logins
        return current
    }
}

/// Somewhere an empty place can be filled from, one of a row to choose
/// among: a browser on this Mac with how much it holds, your card in
/// Contacts, a CSV file. The one chosen is what the one button brings.
struct PlaceSource {
    let name: String
    var icon: NSImage?
    var symbol: String?
    var detail = ""
    /// What its button says and does.
    let take: FieldAction
}

/// What an empty place says, in the middle of it: its mark, with a
/// magnifier on its corner after a search, a heading and a line, the
/// browsers to bring from, and its buttons, the first what ↩ does.
struct PlaceEmpty {
    let place: FieldPlace
    let searching: Bool
    let title: String
    let detail: String
    var footnote: String?
    /// Work under way: a spinner where the buttons would be.
    var busy = false
    var sources: [PlaceSource] = []
    var actions: [FieldAction] = []
}

/// A box on the page the caret was in as the field came up: a sign-in's,
/// or a card's or an address's. What a place fills goes there.
struct PageForm {
    let tab: Tab.ID
    /// The sign-in's site, as the accounts list spells it.
    var login: String?
    var wallet: Browser.WalletChoices?
    /// The box itself, as the page said: a password box, one that takes
    /// lines, what it is called.
    var box: Tab.CaretBox?
    var file: FileQuestion?
    /// The page's host and origin as the field came up: what goes in goes
    /// only into the same page.
    var host = ""
    var origin = ""
}

/// Where ↩ puts the chosen row, said at the field's end: "Into Password ·
/// github.com", or why it won't go in.
struct PlaceTarget: Equatable {
    let what: String
    let host: String
    var refused = false
}

extension Browser {
    // MARK: going in

    /// Straight into a place, from a key, a menu or a list elsewhere: the
    /// field comes up over the page in front, already the place's, with
    /// the words given. The same key again, in the place, puts it away, as
    /// ⌘T again does.
    func openPlace(_ place: FieldPlace, words: String = "", form: PageForm? = nil) {
        // Clear before the same-place toggle can close it. Direct entry
        // cannot inherit a previous field destination, even while it shows.
        query.placeFromField = false
        query.returnPlace = nil
        if fieldShowing, query.place == place, words.isEmpty {
            close()
            if active?.isBlank == false { dismiss() }
            return
        }
        // A card target was captured before the field took focus. Switching
        // from Cmd+T to Cards must not try to discover it again in edit().
        let heldForm = fieldShowing && query.form?.wallet?.group == .card ? query.form : nil
        if !fieldShowing || fresh { if active?.isBlank == false { edit() } else { openFresh() } }
        // From a list hanging under a box on the page: the click took the
        // caret out of the box, but that box is still what a pick fills.
        if let form = form ?? heldForm {
            query.form = form
            query.pageTyping = true
        }
        if query.place != place { enterPlace(place, remember: false) }
        if !words.isEmpty {
            typed = words
            if place == .history { askHistory() }
        }
    }

    /// The last row of the accounts under a sign-in box, or of the cards
    /// under a card's: every one kept, in the box's place, a pick filling
    /// the box the list hung from.
    func openAll(_ place: FieldPlace) {
        let target = place == .passwords ? suggesting?.tab : walletList?.tab
        guard let tab = target.flatMap(autofillTab) ?? active else { return }
        let form = PageForm(tab: tab.id, login: suggesting?.tab == tab.id ? suggesting?.site : nil,
                            wallet: walletList?.tab == tab.id ? walletList : nil,
                            box: tab.caretBox ?? Tab.CaretBox(password: tab.fieldSecret, lines: false, label: "", signIn: true),
                            host: curtain.host(of: tab.address) ?? "", origin: Tab.originOf(tab.address))
        dropChoice()
        walletList = nil
        openPlace(place, form: form)
        if outside.contains(where: { $0.id == tab.id }) { BrowserWindows.shared.show(self) }
    }

    /// What a place reads once as it opens.
    func stockPlace(_ place: FieldPlace) {
        // enterPlace sets the category before asking for rows, including
        // when Cmd-T restores the destination kept by close().
        query.revealed = nil
        query.shown = [:]
        switch place {
        case .passwords:
            query.stock.logins = Vault.entries()
            query.stock.codes = Set(OneTime.ids())
            if query.stock.logins.isEmpty { countSources(.passwords) } else { weighPasswords() }
        case .autofill:
            // Return from a card field fills a card, rather than the profile
            // row that leads Everything and supplies an address.
            if query.form?.wallet?.group == .card { query.placeFilter = 2 }
            query.stock.cards = Wallet.cards()
            query.stock.addresses = Wallet.addresses()
            query.stock.profile = Profile.load()
            query.stock.answered = FormAnswers.load().said.count
            if query.stock.cards.isEmpty && query.stock.addresses.isEmpty { countSources(.autofill) }
            // An empty profile takes your card in Contacts first, when
            // Contacts has said yes before: no question for it, once a launch.
            if query.stock.profile.isEmpty, !FormFill.triedCard, MeCard.allowed {
                FormFill.triedCard = true
                MeCard.fillProfile { [weak self] _ in DispatchQueue.main.async { self?.reloadProfile() } }
            }
        case .history:
            query.stock.threadPages = nil
            query.stock.threadChosen = nil
            askHistory()
            Diary.shared.outline { [weak self] outline in
                guard let self, self.query.place == .history else { return }
                self.query.stock.sites = (outline["sites"] as? [[String: Any]] ?? []).compactMap { site in
                    guard let host = site["host"] as? String else { return nil }
                    return (host, Int(site["n"] as? Int64 ?? 0))
                }
            }
        case .downloads:
            // Mail's files and the words inside all of them, read again.
            FileShelf.shared.refresh()
            FileShelf.shared.learn(loot.kept.filter(\.stillThere).map(\.path))
            var counts: [String: Int] = [:]
            for keep in loot.kept { counts[keep.page?.host() ?? keep.from, default: 0] += 1 }
            // Ties by name, so the list stays put from one opening to the next.
            query.stock.sites = counts.filter { !$0.key.isEmpty }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(6).map { ($0.key, $0.value) }
        case .files:
            if fileScanID == nil { askRecentFiles() }
        case .bookmarks:
            query.stock.folder = nil
            query.stock.recent = false
            if bookmarks.isEmpty { countSources(.bookmarks) }
        case .chats, .routines:
            Chats.shared.load()
        case .now:
            Hints.shared.compose()
        case .store:
            StoreCatalog.shared.refresh()
        case .purchases:
            Purchases.shared.refresh()
        default: break
        }
    }

    /// The box on the page the caret was in, noted as the field comes up.
    func notePageForm() {
        // Files hanging from a page's file box go too, and the page hears
        // that none came: the field's Return is never a pick.
        if query.place != .files && !fileOpening { dropFiles() }
        if query.place == .files, query.form?.file != nil { return }
        // Payment frames report their card target through WalletRelay. The
        // sign-in relay's generic typing flag need not be set for that frame.
        guard let tab = active,
              tab.typing || (walletList?.tab == tab.id && walletList?.group == .card) else {
            query.form = nil
            return
        }
        let wallet = walletList?.tab == tab.id ? walletList : nil
        if wallet?.group == .card { query.pageTyping = true }
        let box = tab.caretBox ?? (wallet?.group == .card ? Tab.CaretBox(password: false, lines: false, label: "", signIn: false) : nil)
        query.form = PageForm(tab: tab.id,
                              login: suggesting?.tab == tab.id ? suggesting?.site : nil,
                              wallet: wallet,
                              box: box, host: curtain.host(of: tab.address) ?? "",
                              origin: Tab.originOf(tab.address))
        // The list hanging under the box goes: the field has the keyboard
        // now, and its arrows are the field's.
        if suggesting != nil { dropChoice() }
        if walletList != nil { walletList = nil }
    }

    // MARK: the rows

    /// The rows of the place open now, as the words and the filter leave
    /// them. Clipboard History and Emoji have their own.
    var placeItems: [PlaceItem] {
        guard let place = query.place else { return [] }
        // Made once for what they depend on, not on every read: a step of
        // the arrows reads them from the list, the preview, the foot and
        // ⌘K, and making them checks every download's file on the disk.
        let stock = query.stock
        let snippetsKey: String = place == .snippets ? MailSnippets.shared.all.map { one -> String in
            "\(one.id)\(one.name)\(one.body.hashValue)\(one.uses)\(one.mailOnly)\(one.hotkey)"
        }.joined() : ""
        let key = ["\(ObjectIdentifier(self))", place.rawValue, typed, "\(query.placeFilter)", "\(loot.version)", active?.address?.host() ?? "",
                   "\(stock.logins.count).\(stock.cards.count).\(stock.addresses.count).\(stock.asked).\(stock.visits.count)",
                   "\(stock.shared.count).\(stock.weak.count).\(stock.leaked.count).\(stock.codes.count).\(stock.version).\(stock.wallets?.count ?? -1)",
                   stock.site ?? "", query.edit.map { $0.new ? $0.title + $0.value("title") : "" } ?? "",
                   place == .bookmarks ? "\(bookmarks.revision).\(stock.folder?.uuidString ?? "").\(stock.recent)" : "",
                   place == .chats ? Chats.shared.all.map { "\($0.id)\($0.pinned)\($0.updated.timeIntervalSince1970)" }.joined() : "",
                   place == .routines ? Routines.shared.all.map { "\($0.id)\($0.name)\($0.when)\($0.off ?? false)\($0.ended?.timeIntervalSince1970 ?? 0)\($0.session ?? "")" }.joined()
                       + Chats.shared.all.filter { $0.unread == true }.map(\.id).joined() : "",
                   "\(stock.files.count).\(fileVersion)",
                   place == .downloads ? "\(FileShelf.shared.version)" : "",
                   place == .purchases ? "\(Purchases.shared.version)" : "",
                   snippetsKey,
                   place == .store ? "\(StoreCatalog.shared.version).\(Boosts.shared.records.count).\(Boosts.shared.records.filter(\.enabled).count)" : "",
                   // Now's rows come and go, and "in 6m" counts down by the minute.
                   // A row handed to the agent says where its task stands (Do It).
                   place == .now ? Hints.shared.queue.map { "\($0.id)\($0.done ?? false)\($0.seen != nil)\(Hints.shared.handedWords($0.id) ?? "")\($0.title)" }.joined() + "\(Int(Hints.now.timeIntervalSince1970 / 60))" : "",
                   hoard.fetches.map { "\($0.id.hashValue)\($0.failed)\($0.paused)" }.joined(),
                   hoard.fetches.isEmpty ? "" : "\(Int(CACurrentMediaTime() * 4))"].joined(separator: "|")
        if let memo = Browser.placeMemo, memo.key == key { return memo.items }
        let items = makePlaceItems(place)
        Browser.placeMemo = (key, items)
        return items
    }

    @MainActor static var placeMemo: (key: String, items: [PlaceItem])?

    private func makePlaceItems(_ place: FieldPlace) -> [PlaceItem] {
        let words = typed.lowercased().split(separator: " ").map(String.init)
        let filter = query.placeFilter
        func finds(_ item: PlaceItem) -> Bool {
            let text = (item.title + " " + item.source + " " + item.search).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        switch place {
        case .files: return query.stock.files.filter { FileRows.matches($0, words: typed) }
        case .downloads: return downloadItems(filter, words: words)
        case .passwords: return loginItems(filter).filter(finds)
        case .autofill:
            let items = walletItems(filter).filter(finds)
            // A card or an address written for the first time stands first.
            if let edit = query.edit, edit.new {
                return [PlaceItem(id: "draft", section: "New", title: edit.title, tile: .symbol("plus"), what: .draft)] + items
            }
            return items
        case .history: return query.stock.visits
        case .bookmarks: return bookmarkItems()
        case .chats: return chatItems().filter(finds)
        case .routines: return routineItems().filter(finds)
        case .snippets:
            let items = snippetItems(words: typed)
            if let edit = query.edit, edit.new {
                return [PlaceItem(id: "draft", section: "New", title: edit.title, tile: .symbol("plus"), what: .draft)] + items
            }
            return items
        case .store: return storeItems()
        case .now: return nowItems(filter).filter(finds)
        case .purchases: return purchaseItems(filter).filter(finds)
        default: return []
        }
    }

    /// Now, all of it: what is still to come first, then the rest, each
    /// in the order the plain list has them.
    private func nowItems(_ filter: Int) -> [PlaceItem] {
        let now = Hints.now
        var hints = nowHints().filter { Browser.nowKind($0, filter) }
        // Promises: the ones whose day hasn't come yet too, under Coming Up.
        if filter == 1 { hints += Promises.shared.upcoming(now: now).filter { one in !hints.contains { $0.id == one.id } } }
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        let coming = { (hint: Hint) in hint.due.map { Hints.promise(hint) ? $0 >= endOfToday : $0 > now } ?? false }
        return (hints.filter(coming) + hints.filter { !coming($0) }).map { hint in
            // Handed to the agent: where its task stands after the words,
            // in the accent while it works or asks, as ⌘T's row says it.
            let handed = Hints.shared.handedWords(hint.id)
            return PlaceItem(id: hint.id, section: coming(hint) ? "Coming Up" : "Today", title: hint.title,
                             source: HintList.detail(hint, now: now), tile: .hint(hint.id), search: hint.detail,
                             tag: handed, fresh: handed == "On it" || handed == "Needs you", what: .hint(hint.id))
        }
    }

    /// Purchases: subscriptions (their monthly total in the heading, the
    /// ones ending after), what is on the way, or receipts by day.
    private func purchaseItems(_ filter: Int) -> [PlaceItem] {
        let book = Purchases.shared
        let now = Date()
        let day = AppDates.formatter()
        day.setLocalizedDateFormatFromTemplate("MMMd")
        switch filter {
        case 1:
            return book.orders.map { item in
                let p = item.purchase
                let arrives = p.arrives.map { Calendar.current.isDateInToday($0) ? "today" : "by " + day.string(from: $0) }
                let section = p.shipping == .delivered ? "Delivered" : p.arrives.map { Calendar.current.isDateInToday($0) } == true ? "Today" : "Coming Up"
                let source = [Purchases.status(p), p.carrier, arrives].compactMap { $0 }.joined(separator: " · ")
                return PlaceItem(id: item.id, section: section, title: p.title, source: source.isEmpty ? p.merchant : source,
                                 tile: .site(p.host ?? p.merchant), search: p.merchant + " " + (p.order ?? "") + " " + (p.tracking ?? ""),
                                 what: .purchase(item.id))
            }
        case 2:
            return book.receipts.map { item in
                let p = item.purchase
                let source = [item.price, p.title == p.merchant ? nil : p.merchant, item.card].compactMap { $0 }.joined(separator: " · ")
                return PlaceItem(id: item.id, section: Browser.day(p.date), title: p.title, source: source,
                                 tile: .site(p.host ?? p.merchant), search: p.merchant + " " + (p.order ?? ""), what: .purchase(item.id))
            }
        default:
            let heading = book.monthlySaid.map { "Subscriptions · " + $0 } ?? "Subscriptions"
            return book.subscriptions.map { item in
                let p = item.purchase
                var source: String
                if p.canceled {
                    source = p.ends.map { "Yours until " + day.string(from: $0) } ?? "Canceled"
                } else {
                    source = [item.price, item.card, p.renews.map { "renews " + day.string(from: $0) }].compactMap { $0 }.joined(separator: " · ")
                }
                let unused = !p.canceled && item.unused(now: now)
                if unused, let idle = item.idle(now: now) {
                    source = (idle >= Purchases.window ? "Not opened this year" : "Not opened in \(idle) days") + " · " + source
                }
                return PlaceItem(id: item.id, section: p.canceled ? "Ending" : heading, title: p.title, source: source,
                                 tile: .site(p.host ?? p.merchant), search: p.merchant, faded: p.canceled,
                                 tag: unused ? "Unused" : nil, alarm: unused, what: .purchase(item.id))
            }
        }
    }

    /// The row chosen in the place.
    var placeItem: PlaceItem? {
        let list = placeItems
        return list.indices.contains(query.spot) ? list[query.spot] : nil
    }

    /// Files: what is coming, then everything downloaded, mail's files
    /// both ways and what you gave sites, newest first. Its filters are
    /// where a file came from, then its kind (FieldPlace.filters). A search
    /// looks in the names, where each came from and the words inside; a
    /// file found by its words says them under its name.
    private func downloadItems(_ filter: Int, words: [String]) -> [PlaceItem] {
        let kinds: [Int: [String]] = [4: ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "tiff"],
                                      5: ["pdf", "doc", "docx", "txt", "md", "rtf", "pages", "key", "numbers", "xls", "xlsx", "csv", "ppt", "pptx"]]
        func kept(_ name: String) -> Bool {
            guard let wanted = kinds[filter] else { return true }
            return wanted.contains((name as NSString).pathExtension.lowercased())
        }
        let site = query.stock.site
        func from(_ host: String) -> Bool { site == nil || host == site || Vault.registrable(host) == site.map(Vault.registrable) }
        let shelf = FileShelf.shared
        /// Whether the words find it, and the line of its words that did
        /// when its name and source didn't.
        func found(_ text: String, path: String?) -> (Bool, String?) {
            guard !words.isEmpty else { return (true, nil) }
            let said = text.lowercased()
            if words.allSatisfy({ said.contains($0) }) { return (true, nil) }
            guard let path, let line = shelf.found(path, terms: words) else { return (false, nil) }
            return (true, line)
        }
        var out: [PlaceItem] = []
        if filter == 0 || filter == 1 || kinds[filter] != nil {
            for fetch in hoard.fetches where kept(fetch.name) && from(fetch.from) && found(fetch.name + " " + fetch.from, path: nil).0 {
                let step = hoard.meter.steps[fetch.id]
                let got = step.map { $0.total > 0 ? "\(ByteCountFormatter.string(fromByteCount: $0.got, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: $0.total, countStyle: .file))" + (Browser.left(fetch, step: $0).map { " · \($0)" } ?? "") : ByteCountFormatter.string(fromByteCount: $0.got, countStyle: .file) }
                out.append(PlaceItem(id: "fetch.\(fetch.id.hashValue)", section: "In Progress", title: fetch.name,
                                     source: fetch.paused ? "Paused · from \(fetch.from)" : fetch.failed ? "Couldn’t download · from \(fetch.from)" : [got, "from \(fetch.from)"].compactMap { $0 }.joined(separator: " · "),
                                     tile: .fetch(fetch), what: .fetch(fetch)))
            }
        }
        var dated: [(date: Date, item: PlaceItem)] = []
        if filter == 0 || filter == 1 || kinds[filter] != nil {
            for keep in loot.kept where kept(keep.name) && from(keep.page?.host() ?? keep.from) {
                let there = keep.stillThere
                var source = "From " + (keep.pageTitle.map { "\(Browser.siteName(keep.page?.host() ?? keep.from)) · \($0)" } ?? keep.from)
                let (hit, line) = found(keep.name + " " + (keep.was.map { $0 + " " } ?? "") + source, path: there ? keep.path : nil)
                guard hit else { continue }
                if !there { source += " · Moved or deleted" }
                dated.append((keep.date, PlaceItem(id: keep.id, section: Browser.day(keep.date), title: keep.name, source: line ?? source,
                                                   tile: .file(keep.path), faded: !there, what: .kept(keep))))
            }
        }
        var others: [ShelfFile] = []
        if filter != 1 { others += shelf.mail.filter { filter == 2 ? !$0.sent : filter == 3 ? $0.sent : true } }
        if filter == 0 || filter == 3 || kinds[filter] != nil { others += shelf.sentFiles }
        for one in others where kept(one.name) {
            let host: String
            switch one.origin {
            case .mail(_, _, _, let person, let to, _, let sent): host = ((sent ? to.first?.address : person.address) ?? "").split(separator: "@").last.map(String.init) ?? ""
            case .upload(let site): host = site
            }
            guard from(host) else { continue }
            let source = one.said + (one.subject.map { " · " + $0 } ?? "")
            let (hit, line) = found(one.name + " " + source, path: one.path)
            guard hit else { continue }
            dated.append((one.date, PlaceItem(id: one.id, section: Browser.day(one.date), title: one.name, source: line ?? source,
                                              tile: .file(one.path ?? one.name), what: .shelf(one))))
        }
        out += dated.sorted { $0.date > $1.date }.map(\.item)
        return out
    }

    /// "12 s left", from how fast it has come so far; nil until it knows.
    static func left(_ fetch: Hoard.Fetch, step: Hoard.Step) -> String? {
        let spent = Date().timeIntervalSince(fetch.started)
        guard step.total > step.got, step.got > 0, spent > 1 else { return nil }
        let seconds = Double(step.total - step.got) / (Double(step.got) / spent)
        guard seconds.isFinite else { return nil }
        if seconds < 60 { return "\(max(1, Int(seconds))) s left" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min left" }
        return "\(Int(seconds / 3600)) h left"
    }

    private func loginItems(_ filter: Int) -> [PlaceItem] {
        let here = active?.address?.host()?.lowercased() ?? ""
        let site = here.isEmpty ? "" : Vault.registrable(here)
        let codes = query.stock.codes
        let stock = query.stock
        let warnings = PasswordListWarnings(stock: stock)
        // The Space each was saved in, once there is more than one to tell
        // apart; one from before Spaces were kept, or shared, says none.
        let names = spaces.count > 1 ? loginSpaceNames : [:]
        let list = query.stock.logins
            .filter {
                switch filter {
                case 1: return ($0.used ?? .distantPast) > Date().addingTimeInterval(-30 * 86400)
                case 2: return codes.contains($0.id)
                case 3, 4, 5: return warnings.contains($0.id, filter: filter)
                default: return true
                }
            }
            .sorted { ($0.used ?? $0.saved ?? .distantPast) > ($1.used ?? $1.saved ?? .distantPast) }
        let mine = list.filter { !site.isEmpty && Vault.registrable($0.host) == site }
        // Used lately: the latest first, as they were used.
        let rest = list.filter { site.isEmpty || Vault.registrable($0.host) != site }
            .sorted { filter == 1 ? ($0.used ?? .distantPast) > ($1.used ?? .distantPast) : $0.host == $1.host ? $0.user < $1.user : $0.host < $1.host }
        return (mine.map { ($0, "This Site") } + rest.map { ($0, "All Accounts") }).map { entry, section in
            PlaceItem(id: "login." + entry.id, section: section, title: entry.host,
                      source: entry.user + (codes.contains(entry.id) ? " · One-time code" : "") + (entry.space.flatMap { names[$0] }.map { " · " + $0 } ?? ""),
                      tile: .site(entry.host),
                      tag: stock.leaked[entry.id] != nil ? "leaked" : (stock.shared[entry.id] ?? 0) > 0 ? "reused" : stock.weak.contains(entry.id) ? "weak" : nil,
                      alarm: stock.leaked[entry.id] != nil, what: .login(entry))
        }
    }

    private func walletItems(_ filter: Int) -> [PlaceItem] {
        var out: [PlaceItem] = []
        // Everything, You, Cards, Addresses.
        if filter == 0 || filter == 1 { out.append(profileItem()) }
        if filter != 1, let bring = bringItem(filter) { out.append(bring) }
        if filter == 0 || filter == 2 {
            let cards = query.stock.cards.sorted { $0.expired == $1.expired ? ($0.used ?? .distantPast) > ($1.used ?? .distantPast) : !$0.expired }
            for card in cards {
                out.append(PlaceItem(id: "card." + card.id, section: "Cards", title: card.shortTitle,
                                     source: [card.nickname.isEmpty ? card.name : card.nickname, card.expired ? "Expired \(card.expiry)" : "Expires \(card.expiry)"].filter { !$0.isEmpty }.joined(separator: " · "),
                                     tile: .pay(card.brand), search: [card.title, card.name, card.nickname, card.from, card.source].joined(separator: " "),
                                     faded: card.expired,
                                     tag: card.expired ? "expired" : card.soon != nil ? "expires soon" : nil, what: .card(card)))
            }
        }
        if filter == 0 || filter == 3 {
            for address in query.stock.addresses {
                out.append(PlaceItem(id: "address." + address.id, section: "Addresses", title: address.title,
                                     source: [address.line1, address.place].filter { !$0.isEmpty }.joined(separator: ", "),
                                     tile: .symbol(address.mark),
                                     search: [address.name, address.organization, address.street, address.city, address.region,
                                              address.postal, address.country, address.phone, address.email].joined(separator: " "),
                                     what: .address(address)))
            }
        }
        return out
    }

    /// History's rows for the words and the filter now, from the diary, on
    /// its own queue. Until they come the rows before them stay. `more`: the
    /// next rows after the last listed, as the list is scrolled to its end.
    func askHistory(more: Bool = false) {
        if !more {
            query.historySearchWork?.cancel()
            query.historySearchWork = nil
        }
        if more {
            guard query.placeFilter != FieldPlace.byThread, query.stock.threadPages == nil,
                  !query.stock.ended, typed.trimmingCharacters(in: .whitespaces).isEmpty,
                  case .visit(_, _, _, let last, _)? = query.stock.visits.last?.what else { return }
            query.stock.ended = true
            let before = last.timeIntervalSince1970
            let known = Set(query.stock.visits.map(\.id))
            Diary.shared.list(before: before, from: historyFrom(), host: query.stock.site, limit: 80) { [weak self] rows in
                guard let self, self.query.place == .history else { return }
                let items = self.visitItems(rows, words: "").filter { !known.contains($0.id) }
                self.query.stock.visits += items
                self.query.stock.ended = rows.count < 80
            }
            return
        }
        query.stock.asked += 1
        query.stock.ended = false
        let asked = query.stock.asked
        let words = typed.trimmingCharacters(in: .whitespaces)
        if query.placeFilter == FieldPlace.byThread { return askThreads(asked, words: words) }
        if let thread = query.stock.threadPages, words.isEmpty { return listThread(thread) }
        let from = historyFrom()
        let take: ([[String: Any]]) -> Void = { [weak self] rows in
            guard let self, self.query.stock.asked == asked, self.query.place == .history else { return }
            self.query.stock.visits = self.visitItems(rows, words: words)
            self.query.stock.ended = !words.isEmpty || rows.count < 80
            if self.query.spot >= self.query.stock.visits.count { self.query.spot = max(0, self.query.stock.visits.count - 1) }
        }
        if words.isEmpty {
            Diary.shared.list(before: nil, from: from, host: query.stock.site, limit: 80, done: take)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.query.stock.asked == asked, self.query.place == .history else { return }
                Diary.shared.search(self.query.stock.site.map { "site:\($0) " + words } ?? words) {
                    result in take(result["results"] as? [[String: Any]] ?? [])
                }
            }
            query.historySearchWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }

    /// Where History's filter starts it: today, this week, or all of it.
    private func historyFrom() -> Double? {
        let calendar = Calendar.current
        switch query.placeFilter {
        case 1: return calendar.startOfDay(for: Date()).timeIntervalSince1970
        case 2: return Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970
        default: return nil
        }
    }

    /// The diary's rows as History's.
    func visitItems(_ rows: [[String: Any]], words: String) -> [PlaceItem] {
        let from = historyFrom()
        return rows.compactMap { row in
            guard let link = row["url"] as? String, let url = URL(string: link) else { return nil }
            let at = Date(timeIntervalSince1970: (row["at"] as? Double ?? 0) / 1000)
            if let from, at.timeIntervalSince1970 < from { return nil }
            let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Address.pretty(url)
            let host = row["host"] as? String ?? url.host() ?? ""
            let key = row["key"] as? String ?? link
            let count = (row["count"] as? Int) ?? Int(row["count"] as? Int64 ?? 1)
            // Found by what the page said: that passage under its name,
            // and ↩ goes to the words on the page.
            let passage = (row["passage"] as? String)?.replacingOccurrences(of: "\u{2}", with: "").replacingOccurrences(of: "\u{3}", with: "")
                .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if let passage, !passage.isEmpty, !words.isEmpty,
               let jump = URL(string: link.components(separatedBy: "#")[0] + "#:~:text=" + (words.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) {
                query.stock.jumps[key] = jump
            }
            return PlaceItem(id: "visit.\(key).\(Int(at.timeIntervalSince1970))", section: Browser.day(at), title: title,
                             source: passage.flatMap { $0.isEmpty ? nil : "…\($0)…" } ?? "\(host) · \(at.englishFormatted(date: .omitted, time: .shortened))",
                             tile: .site(host), what: .visit(url: url, title: title, key: key, at: at, count: count))
        }
    }

    /// The chats kept: those kept for good, then by the day they were last
    /// touched, each with its agent, when, and the start of its answer.
    private func chatItems() -> [PlaceItem] {
        // Projects first, as Spotlight puts a contact over its messages:
        // ↩ opens one, ⌘↩ asks in it.
        let projects = Projects.shared.listed.map { project in
            PlaceItem(id: "project." + project.id, section: "Projects", title: project.name,
                      source: ChatProjectCard.count(chats: Chats.shared.of(project: project.id).count,
                                                    routines: Routines.shared.all.filter { $0.project == project.id }.count),
                      tile: .project(project.id), search: project.instructions, what: .project(project.id))
        }
        return projects + Chat.listed(Chats.shared.all).map { chat in
            let live = Agents.shared.session(chat.id)?.state.live == true
            let when = Calendar.current.isDateInToday(chat.updated) ? chat.updated.englishFormatted(date: .omitted, time: .shortened)
                                                                     : Browser.day(chat.updated)
            let gist = Chat.plain(chat.answer)
            let project = Projects.shared.project(chat.project).map { "in " + $0.name }
            return PlaceItem(id: "chat." + chat.id, section: chat.section(), title: chat.title,
                             source: [AgentSetupModel.name(chat.cli), project, when, gist.isEmpty ? nil : gist].compactMap { $0 }.joined(separator: " · "),
                             tile: .symbol(FieldAnswer.mark(chat.cli)), search: chat.words, tag: live ? "working" : nil, what: .chat(chat.id))
        }
    }

    /// The snippets: one line each, the name and
    /// what is typed for it, under when it was last used (This Month, This
    /// Year, Earlier), the last used first. Searched, by name first, then
    /// by their words.
    private func snippetItems(words: String) -> [PlaceItem] {
        let snippets = MailSnippets.shared
        let needle = words.trimmingCharacters(in: .whitespaces).lowercased()
        let list: [MailSnippet]
        if needle.isEmpty {
            list = snippets.all.sorted { ($0.used ?? $0.made) > ($1.used ?? $1.made) }
        } else {
            let named = snippets.matching(words)
            list = named + snippets.ordered.filter { snippet in
                !named.contains { $0.id == snippet.id } && snippet.body.lowercased().contains(needle)
            }
        }
        let calendar = Calendar.current
        let now = Date()
        return list.map { snippet in
            let when = snippet.used ?? snippet.made
            let section = needle.isEmpty
                ? calendar.isDate(when, equalTo: now, toGranularity: .month) ? "This Month"
                    : calendar.isDate(when, equalTo: now, toGranularity: .year) ? "This Year" : "Earlier"
                : "Snippets"
            return PlaceItem(id: "snippet." + snippet.id, section: section, title: snippet.name,
                             tile: .symbol("doc"), search: snippet.body, tag: ";" + snippet.name, what: .snippet(snippet.id))
        }
    }

    /// What a snippet's row does: put in the page's box the caret was in, or
    /// copied; written in place, deleted.
    private func snippetActions(_ id: String) -> [FieldAction] {
        guard let snippet = MailSnippets.shared.snippet(id) else { return [] }
        let words = MailSnippets.fillPage(snippet.body, date: Date())
        let copy = FieldAction(id: "copy", title: "Copy Words", keys: Keymap.shared.text(.fieldCopy), symbol: "yab.copyframe.text") {
            self.close()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(words, forType: .string)
            MailSnippets.shared.used(id)
        }
        var out: [FieldAction] = []
        if pastesIntoPage, !snippet.mailOnly, let tab = active {
            out.append(FieldAction(id: "paste", title: "Put into Page", symbol: "yab.text.right") {
                self.close()
                PageSnippets.shared.put(snippet, into: tab, replacing: false, after: 0.08)
            })
        }
        out.append(copy)
        out.append(FieldAction(id: "edit", title: "Edit Snippet", keys: Keymap.shared.text(.fieldEdit), symbol: "pencil", group: 1) {
            self.beginEdit(.snippet(id))
        })
        out.append(FieldAction(id: "settings", title: "Edit in Settings…", symbol: "gearshape", group: 1) {
            self.close()
            self.openSettings(.snippets)
        })
        out.append(FieldAction(id: "new", title: "New Snippet", keys: Keymap.shared.text(.fieldNew), symbol: "yab.doc.plus", group: 2) {
            self.beginEdit(.snippet(nil))
        })
        out.append(FieldAction(id: "delete", title: "Delete Snippet", keys: Keymap.shared.text(.fieldDelete), symbol: "trash", group: 3) {
            self.did(MailSnippets.shared.removeUndoably(id))
            self.query.spot = min(self.query.spot, max(0, self.placeItems.count - 1))
        })
        return out
    }

    /// The routines set: what each came to last, the ones running and the
    /// ones with something new first, then the watches, then those off.
    private func routineItems() -> [PlaceItem] {
        let routines = Routines.shared.all
        func live(_ routine: Routine) -> Bool { Agents.shared.session(routine.session)?.state.live == true }
        func fresh(_ routine: Routine) -> Bool { routine.chat.flatMap { Chats.shared.chat($0) }?.unread == true }
        let ordered = routines.filter { live($0) || fresh($0) } + routines.filter { !live($0) && !fresh($0) && $0.off != true && $0.quiet != true }
            + routines.filter { !live($0) && !fresh($0) && $0.quiet == true } + routines.filter { !live($0) && !fresh($0) && $0.off == true && $0.quiet != true }
        return ordered.map { routine in
            let section = routine.off == true ? "Off" : routine.quiet == true ? "Watching" : "Routines"
            return PlaceItem(id: "routine." + routine.id, section: section, title: routine.name,
                             source: Routines.short(routine.when) + " · " + Routines.status(routine, live: live(routine)),
                             tile: Routines.hosts(routine).first.map { .site($0) } ?? .symbol(FieldPlace.routines.symbol),
                             search: routine.prompt, faded: routine.off == true,
                             tag: live(routine) ? "running" : fresh(routine) ? "new" : nil,
                             fresh: !live(routine) && fresh(routine), what: .routine(routine.id))
        }
    }

    // MARK: passwords weighed

    /// Which passwords are shared, easy to guess or seen in a breach, read
    /// off the main thread; a breach only once the check is on (the
    /// passwords page asks first), at most once a launch.
    func weighPasswords() {
        let reading = UUID()
        query.stock.passwordAnalysis = reading
        DispatchQueue.global(qos: .utility).async {
            let analysis = Vault.analysis()
            var groups: [String: Int] = [:]
            for (_, value) in analysis { groups[value.group, default: 0] += 1 }
            let shared = analysis.compactMapValues { value -> Int? in
                let others = (groups[value.group] ?? 1) - 1
                return others > 0 ? others : nil
            }
            let weak = Set(analysis.filter(\.value.weak).map(\.key))
            let owned = analysis.mapValues(\.group)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.query.place == .passwords,
                      self.query.stock.passwordAnalysis == reading else { return }
                self.replacePasswordWarnings(PasswordListWarnings(
                    groups: owned, shared: shared, weak: weak,
                    leaked: Browser.leaks ?? self.query.stock.leaked))
            }
        }
        guard Leaks.enabled, Browser.leaks == nil else { return }
        Leaks.check { found, _ in
            DispatchQueue.main.async { [weak self] in
                Browser.leaks = found
                guard let self, self.query.place == .passwords,
                      self.query.stock.passwordAnalysis == reading else { return }
                var warnings = PasswordListWarnings(stock: self.query.stock)
                warnings.leaked = found
                self.replacePasswordWarnings(warnings)
            }
        }
    }

    /// The last breach check's answer, kept for the launch.
    @MainActor static var leaks: [String: Int]?

    /// What the chosen login's warnings say, as the passwords page says them.
    func warning(for entry: Vault.Entry) -> String? {
        if let times = query.stock.leaked[entry.id] {
            return "Seen in a breach \(times == 1 ? "once" : "\(times) times"). Anyone trying leaked passwords will try this one. Change it on \(Browser.site(entry.host))."
        }
        if let others = query.stock.shared[entry.id] {
            // The others named, as the page named them: up to three.
            let group = query.stock.groups[entry.id]
            let hosts = Array(NSOrderedSet(array: query.stock.logins
                .filter { $0.id != entry.id && group != nil && query.stock.groups[$0.id] == group }
                .map { Browser.site($0.host) }.filter { $0 != Browser.site(entry.host) })) as? [String] ?? []
            if !hosts.isEmpty {
                let named = hosts.count <= 3 ? hosts : Array(hosts.prefix(2))
                let tail = hosts.count <= 3 ? "" : " and \(hosts.count - 2) more"
                let list = named.count == 1 ? named[0] : tail.isEmpty ? named.dropLast().joined(separator: ", ") + " and " + named.last! : named.joined(separator: ", ") + tail
                return "Same password on \(list). One leak opens all of them. Change it here first."
            }
            return "Same password on \(others == 1 ? "one other site" : "\(others) other sites"). One leak opens all of them."
        }
        if query.stock.weak.contains(entry.id) {
            return "Easy to guess. Short, common, or made of your name or the site’s. Change it on the site; Yab keeps the new one when you sign in."
        }
        return nil
    }

    // MARK: exports

    /// Every password, as a CSV Chrome, 1Password and the rest read:
    /// asked first, since the file isn't encrypted, then Touch ID, then
    /// where to put it.
    func exportPasswords() {
        let count = Vault.entries().count
        guard count > 0 else { return }
        close()
        Task { @MainActor in
            let yes = await Questions.shared.ask(Question(
                title: "Export \(count) password\(count == 1 ? "" : "s")?",
                detail: "The file isn’t encrypted: anyone who opens it sees every password. Delete it once it is where it’s going.",
                glyph: "key", yes: "Export…"
            ))
            guard yes else { return }
            self.proveOwner("export your passwords") {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "Yab Passwords.csv"
                panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                panel.allowedContentTypes = [.commaSeparatedText]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    var lines = ["name,url,username,password,note"]
                    for login in Vault.all() {
                        lines.append([login.host, "https://" + login.host, login.user, login.password, ""].map(Browser.cell).joined(separator: ","))
                    }
                    try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
                }
            }
        }
    }

    /// Every page visited, as a CSV this app and others read back.
    func exportHistory() {
        close()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Yab History.csv"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Diary.shared.list(before: nil, limit: 1_000_000) { rows in
            DispatchQueue.global(qos: .utility).async {
                let format = ISO8601DateFormatter()
                var lines = ["url,title,visited,visits"]
                for row in rows {
                    let at = Date(timeIntervalSince1970: (row["at"] as? Double ?? 0) / 1000)
                    lines.append([row["url"] as? String ?? "", row["title"] as? String ?? "", format.string(from: at),
                                  "\(row["count"] as? Int64 ?? 1)"].map(Browser.cell).joined(separator: ","))
                }
                try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
            }
        }
    }

    /// One cell of a CSV, quoted when it has to be.
    nonisolated static func cell(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// History from a moment on, gone after a yes: the last hour, today,
    /// today and yesterday, all of it.
    func forgetRecent(_ span: Int) {
        let calendar = Calendar.current
        let starts: [Date] = [Date().addingTimeInterval(-3600), calendar.startOfDay(for: Date()),
                              calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) ?? Date(), .distantPast]
        let names = ["from the last hour", "from today", "from today and yesterday", "all of it"]
        guard starts.indices.contains(span) else { return }
        close()
        Task { @MainActor in
            let yes = await Questions.shared.ask(Question(
                title: span == 3 ? "Forget all your history?" : "Forget your history \(names[span])?",
                detail: "Everything from then goes, not only what’s shown. This can’t be undone.",
                glyph: "clock", yes: "Forget", danger: true
            ))
            guard yes else { return }
            if span == 3 { self.clearHistory() } else {
                Diary.shared.forget(since: starts[span]) {}
                self.history.forget(since: starts[span])
                // The sites searched lately go with them, as the page had it.
                Scopes.forgetAsked()
            }
        }
    }

    // MARK: empty

    /// What the place says when its list is empty: nothing kept yet, or
    /// nothing found for the words.
    /// A kind or a site with nothing under it, in a place that has
    /// something: said as a search that found nothing is, ↩ back to all of
    /// it, rather than the place's welcome.
    private func narrowedEmpty(_ place: FieldPlace) -> PlaceEmpty? {
        let filter = query.placeFilter
        let site = query.stock.site.map(Browser.site)
        guard filter != 0 || site != nil else { return nil }
        func pick(_ words: [String]) -> String { words.indices.contains(filter) ? words[filter] : words[0] }
        let title: String
        switch place {
        case .passwords:
            guard !query.stock.logins.isEmpty else { return nil }
            title = pick(["Nothing here", "Nothing used in the last 30 days", "No accounts with one-time codes",
                          "No leaked passwords", "No reused passwords", "No weak passwords"])
        case .downloads:
            guard !loot.kept.isEmpty || !hoard.fetches.isEmpty else { return nil }
            title = pick(["No files", "Nothing downloaded", "No files from mail", "Nothing sent", "No images", "No documents"]) + (site.map { " from " + $0 } ?? "")
        case .purchases:
            let book = Purchases.shared
            guard !book.subscriptions.isEmpty || !book.orders.isEmpty || !book.receipts.isEmpty else { return nil }
            title = pick(["No subscriptions", "Nothing on the way", "No receipts"]) + " in your mail"
        case .now:
            guard !nowHints().isEmpty else { return nil }
            title = pick(["Nothing", "No promises", "No mail", "No meetings", "Nothing from agents", "No links copied", "Nothing from your iPhone"]) + " in Now"
        default:
            return nil
        }
        return PlaceEmpty(place: place, searching: true, title: title, detail: "",
                          actions: [FieldAction(id: "all", title: "Show " + (place.filters.first ?? ""), symbol: place.filterSymbols.first ?? "list.bullet") {
                              self.query.placeFilter = 0
                              self.keepToSite(nil)
                          }])
    }

    var placeEmpty: PlaceEmpty? {
        guard let place = query.place, place != .clipboard, place != .emoji else { return nil }
        if query.edit == nil, let bringing = bringingEmpty { return bringing }
        guard placeItems.isEmpty else { return nil }
        let words = typed.trimmingCharacters(in: .whitespaces)
        let searching = !words.isEmpty
        if !searching, let narrowed = narrowedEmpty(place) { return narrowed }
        switch place {
        case .files:
            return fileEmpty(words: words)
        case .downloads:
            if searching {
                return PlaceEmpty(place: place, searching: true, title: "Nothing for “\(words)”",
                                  detail: "Files are found by their name, where they came from and the words in them.")
            }
            return PlaceEmpty(place: place, searching: false, title: "Nothing downloaded yet",
                              detail: "Files you download land in \(currentDownloadFolder.lastPathComponent) and are listed here, one Return from the Finder.",
                              actions: [
                                  FieldAction(id: "folder", title: "Open Downloads Folder", symbol: "yab.folder.down", image: ActionIcons.file(currentDownloadFolder)) {
                                      self.close()
                                      NSWorkspace.shared.open(self.currentDownloadFolder)
                                  },
                                  FieldAction(id: "where", title: "Change Where They Go…", symbol: "gearshape") {
                                      let space = self.prefs.usesSpaces ? self.spaces.first { $0.id == self.spaceID } : nil
                                      let custom = space.flatMap { DownloadFolder.custom(for: $0.id) }
                                      self.close()
                                      if let space, custom != nil {
                                          SettingsWindow.shared.showSpace(space.id, for: self)
                                      } else {
                                          self.openSettings(.general)
                                      }
                                  },
                              ])
        case .passwords:
            if searching {
                let found = elsewhereFound(words)
                if let first = found.first {
                    let many = found.count
                    return PlaceEmpty(place: place, searching: true, title: "Nothing for “\(words)” in Yab",
                                      detail: many == 1 ? "\(first.from) has 1 you haven’t brought in: \(first.login.host), \(first.login.user)."
                                                        : "\(first.from) has \(many) you haven’t brought in.",
                                      actions: [FieldAction(id: "bring", title: many == 1 ? "Bring It In" : "Bring Them In", symbol: "tray.and.arrow.down") {
                                          _ = Vault.take(Chromium.Found(logins: found.map(\.login), never: []))
                                          self.query.stock.elsewhere = nil
                                          self.query.stock.logins = Vault.entries()
                                          self.typed = self.typed
                                      }])
                }
                return PlaceEmpty(place: place, searching: true, title: "Nothing for “\(words)”",
                                  detail: query.stock.elsewhere == nil ? "Not in Yab. Looking in your other browsers…" : "Not in Yab, and not in your other browsers either.")
            }
            // The browsers, Safari, then a CSV file: one chosen, one button.
            let sources = placeSources(.passwords)
            let chosen = sources[min(query.spot, sources.count - 1)]
            return PlaceEmpty(place: place, searching: false, title: "Your passwords, kept by Yab",
                              detail: "Yab fills them in when you sign in and keeps new ones when you ask it to. They stay in this Mac’s keychain.",
                              footnote: chosen.name == "Safari" ? "Safari’s own export is the one way to its passwords." : chosen.symbol == nil ? "macOS asks once for \(chosen.name)’s key. Nothing changes in \(chosen.name)." : "A CSV from Chrome, Dia or Google Password Manager.",
                              sources: sources, actions: [chosen.take])
        case .autofill:
            if searching {
                return PlaceEmpty(place: place, searching: true, title: "Nothing for “\(words)”", detail: "Cards are found by their name and last digits, addresses by any line.")
            }
            // You always stand in the list, so this is a search that found
            // nothing, or a filter with nothing under it.
            return PlaceEmpty(place: place, searching: false, title: query.placeFilter == 2 ? "No cards yet" : "No addresses yet",
                              detail: "Yab fills them in where you pay or ship. A card fills only after Touch ID.",
                              actions: [FieldAction(id: "new", title: query.placeFilter == 2 ? "New Card" : "New Address", symbol: query.placeFilter == 2 ? "yab.card.plus" : "yab.home.plus") {
                                  self.beginEdit(self.query.placeFilter == 2 ? .card(nil) : .address(nil))
                              }, FieldAction(id: "more", title: "Bring In…", symbol: "tray.and.arrow.down") { self.bringMore() }])
        case .bookmarks:
            return bookmarksEmpty(words: words)
        case .chats:
            if searching {
                return PlaceEmpty(place: place, searching: true, title: "Nothing for “\(words)”",
                                  detail: "Chats are found by their title, what you asked and what the agent answered.")
            }
            return PlaceEmpty(place: place, searching: false, title: "No chats yet",
                              detail: "Your chats with agents come here. Untouched ones go to Archived Chats after a while; pinned ones stay.")
        case .snippets:
            let new = FieldAction(id: "new", title: "New Snippet", keys: Keymap.shared.text(.fieldNew), symbol: "yab.doc.plus") {
                self.beginEdit(.snippet(nil))
            }
            if searching {
                return PlaceEmpty(place: place, searching: true, title: "No snippet named “\(words)”",
                                  detail: "Snippets are found by their names and their words.", actions: [new])
            }
            return PlaceEmpty(place: place, searching: false, title: "No snippets yet",
                              detail: "Words you write again and again: type ; and a snippet’s name in any box to put them in.",
                              actions: [new])
        case .routines:
            if searching {
                return PlaceEmpty(place: place, searching: true, title: "Nothing for “\(words)”",
                                  detail: "Routines are found by their name and what they are told to do.")
            }
            let newTabKey = Keymap.shared.text(.newTab)
            let newTabPlace = newTabKey.isEmpty ? "New Tab" : "New Tab (\(newTabKey))"
            return PlaceEmpty(place: place, searching: false, title: "No routines yet",
                              detail: "A task that comes back on its own, while Yab is open: what it finds waits in \(newTabPlace) and in its chat.",
                              actions: [FieldAction(id: "new", title: "New Routine…", symbol: "plus") {
                                  self.close()
                                  SettingsWindow.shared.showRoutine(nil, for: self)
                              }])
        case .history:
            if query.placeFilter == FieldPlace.byThread { return threadEmpty }
            if searching {
                return PlaceEmpty(place: place, searching: true, title: "Nothing for “\(words)”",
                                  detail: words.contains(" ") ? "None of these words was on a page you opened." : "One word looks in titles and addresses. Add another and it looks through what the pages said too.",
                                  actions: [FieldAction(id: "web", title: "Search the Web", symbol: "magnifyingglass") {
                                      guard let url = self.searchEngine.url(for: words) else { return }
                                      let asking = self.asking
                                      self.close()
                                      self.place(url, asking, from: nil)
                                  }])
            }
            return PlaceEmpty(place: place, searching: false, title: "Nothing here yet",
                              detail: "Pages you open are kept here, newest first, and found again by their title, their site or what they said.")
        case .now:
            if searching {
                return PlaceEmpty(place: place, searching: true, title: "Nothing for “\(words)”",
                                  detail: "Now’s rows are found by their words and what is said under them.")
            }
            return PlaceEmpty(place: place, searching: false, title: "Nothing in Now",
                              detail: "A meeting about to start, mail to answer, a link just copied and what agents found come here as they happen.")
        case .purchases:
            if searching {
                return PlaceEmpty(place: place, searching: true, title: "Nothing for “\(words)”",
                                  detail: "Purchases are found by the shop and what was bought.")
            }
            return PlaceEmpty(place: place, searching: false, title: "No purchases yet",
                              detail: "Receipts, renewals and shipping mail in your inbox come here: what you pay for each month, what is on the way, and every receipt.")
        default:
            return nil
        }
    }

    /// The browsers on this Mac with passwords, or cards and addresses, to
    /// bring in, counted without their keys, off the main thread.
    func countSources(_ place: FieldPlace) {
        if place == .bookmarks { return countBookmarkSources() }
        query.stock.sources = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Chromium.installed()
            let wallets = found.map { (source: $0, cards: 0, addresses: 0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.query.place == place else { return }
                if place == .autofill { self.query.stock.wallets = wallets }
                self.query.stock.sources = found.map { source in
                    PlaceSource(name: source.name, icon: source.icon, detail: "",
                                take: FieldAction(id: "bring", title: "Bring In from \(source.name)", symbol: "tray.and.arrow.down") {
                                    if place == .passwords { self.bringPasswords(source) } else { self.bringWallet(source) }
                                })
                }
            }
        }
    }

    /// Passwords from a browser on this Mac: its key asked for once, the
    /// count said as they are kept, and what went wrong if it did.
    private func bringPasswords(_ source: Chromium.Source) {
        let source = source.authorizingImport()
        query.stock.bringing = source.name
        query.stock.keeping = nil
        let retry = FieldAction(id: "retry", title: "Try Again", symbol: "yab.reload") {
            self.query.stock.trouble = nil
            self.bringPasswords(source)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try Chromium.read(source) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch outcome {
                case .success(let found):
                    // Kept one by one, the count said as it goes.
                    DispatchQueue.global(qos: .userInitiated).async {
                        var said = Date.distantPast
                        _ = Vault.take(found) { done, all in
                            guard Date().timeIntervalSince(said) > 0.1 || done == all else { return }
                            said = Date()
                            DispatchQueue.main.async { if self.query.place == .passwords { self.query.stock.keeping = (done, all) } }
                        }
                        DispatchQueue.main.async {
                            guard self.query.place == .passwords else { return }
                            self.query.stock.bringing = nil
                            self.query.stock.keeping = nil
                            _ = self.leaveMore()
                            self.restock()
                        }
                    }
                case .failure(Chromium.Trouble.noPassphrase):
                    self.query.stock.bringing = nil
                    self.query.stock.trouble = PlaceTrouble(title: "\(source.name) didn’t hand over its key",
                                                            detail: "macOS asked for your password to open \(source.name)’s passwords and it was turned down. Try again and choose Always Allow.",
                                                            retry: retry)
                case .failure:
                    self.query.stock.bringing = nil
                    self.query.stock.trouble = PlaceTrouble(title: "Couldn’t read \(source.name)’s passwords",
                                                            detail: "Quit \(source.name) and try again: it may be holding its files.", retry: retry)
                }
            }
        }
    }

    /// Searching Yab's passwords is not permission to read another browser.
    func lookElsewhere() {}

    /// Logins the other browsers hold that the words find and yab doesn't.
    private func elsewhereFound(_ words: String) -> [(login: Login, from: String)] {
        let word = words.lowercased()
        guard word.count >= 2, let all = query.stock.elsewhere else { return [] }
        let have = Set(query.stock.logins.map(\.id))
        var seen = Set<String>()
        return all.filter {
            !have.contains($0.login.id) && seen.insert($0.login.id).inserted
                && ($0.login.host.lowercased().contains(word) || $0.login.user.lowercased().contains(word))
        }
    }

    /// A day as a heading: Today, Yesterday, Monday, or the date, with its
    /// year when it isn't this one.
    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(AppDates.dateTime.weekday(.wide))
        }
        if !calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(AppDates.dateTime.month(.wide).day().year())
        }
        return date.formatted(AppDates.dateTime.month(.wide).day())
    }

    /// A site's name as a person says it: stripe.com is Stripe.
    static func siteName(_ host: String) -> String {
        let bare = Vault.registrable(host)
        let name = bare.split(separator: ".").first.map(String.init) ?? bare
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: what a row can have done to it

    /// The chosen row's actions, the first what ↩ does.
    func placeActions(_ item: PlaceItem) -> [FieldAction] {
        switch item.what {
        case .file(let url): return fileActions(url)
        case .kept(let keep): return query.place == .files ? fileActions(keep.url) : keptActions(keep)
        case .shelf(let one): return query.place == .files ? one.path.map { fileActions(URL(fileURLWithPath: $0)) } ?? [] : shelfActions(one)
        case .fetch(let fetch): return fetchActions(fetch)
        case .login(let entry): return loginActions(entry)
        case .card(let card): return cardActions(card)
        case .address(let address): return addressActions(address)
        // A page in History or Bookmarks can be a favorite too (FieldFavorites).
        case .visit(let url, let title, let key, _, _): return favoriting(url, named: title, visitActions(url, title: title, key: key))
        case .thread(let thread): return threadActions(thread)
        case .bookmark(let node):
            guard let url = node.url.flatMap(URL.init(string:)) else { return bookmarkActions(node) }
            return favoriting(url, named: node.title, bookmarkActions(node))
        case .chat(let id): return chatActions(id)
        case .project(let id): return projectActions(id)
        case .routine(let id): return routineActions(id)
        case .snippet(let id): return snippetActions(id)
        case .profile: return profileActions()
        case .draft: return editActions
        case .bring: return bringActions()
        case .boost(let id): return storeActions(id)
        case .storeMake(let kind): return storeMakeActions(kind)
        case .hint(let id): return hintActions(id)
        case .purchase(let id): return purchaseActions(id)
        }
    }

    /// The list kept to one site, or back to all of them.
    private func onlySite(_ host: String, _ place: FieldPlace) -> FieldAction {
        let now = query.stock.site
        return FieldAction(id: "site", title: now == nil ? "Only \(Browser.site(host))" : "All Sites", symbol: "line.3.horizontal.decrease", group: 4) {
            self.keepToSite(now == nil ? host : nil)
        }
    }

    /// History or Downloads kept to one site, from ⌘K or the filter's menu.
    func keepToSite(_ host: String?) {
        query.stock.site = host
        query.spot = 0
        query.unpick()
        query.stock.version += 1
        if query.place == .history { askHistory() }
    }

    private func keptActions(_ keep: Keep) -> [FieldAction] {
        var out: [FieldAction] = []
        let back = keep.page.map { page in
            FieldAction(id: "page", title: "Return to Page", keys: Keymap.shared.text(.fieldPage), symbol: "yab.page.left", group: 1, image: ActionIcons.site(page)) {
                self.close()
                self.open(page, foreground: true)
            }
        }
        if keep.stillThere {
            out.append(FieldAction(id: "open", title: "Open", symbol: "arrow.up.right", image: ActionIcons.app(opening: keep.url)) {
                self.close()
                self.loot.open(keep)
            })
            out.append(FieldAction(id: "copy", title: "Copy File", keys: Keymap.shared.text(.fieldCopy), symbol: "yab.copyframe.doc", group: 1) {
                self.close()
                let board = NSPasteboard.general
                board.clearContents()
                board.writeObjects([keep.url as NSURL])
            })
            if let back { out.append(back) }
            out.append(FieldAction(id: "reveal", title: "Show in Finder", keys: Keymap.shared.text(.fieldReveal), symbol: "yab.folder.search", group: 1, image: ActionIcons.finder()) {
                self.close()
                self.loot.reveal(keep)
            })
            out.append(FieldAction(id: "second", title: "Copy Path", keys: Keymap.shared.text(.fieldSecond), symbol: "yab.copyframe.folder", group: 1) {
                self.copyPlain(keep.path)
            })
        } else if let back {
            out.append(back)
        }
        out.append(FieldAction(id: "delete", title: "Remove from List", keys: Keymap.shared.text(.fieldDelete), symbol: "xmark", group: 3) {
            self.loot.forget(keep)
            self.query.spot = min(self.query.spot, max(0, self.placeItems.count - 1))
        })
        out.append(onlySite(keep.page?.host() ?? keep.from, .downloads))
        out.append(contentsOf: downloadsKit())
        return out
    }

    /// A file of mail's or one you gave a site. Mail's is fetched the
    /// first time it is opened, copied or shown.
    private func shelfActions(_ one: ShelfFile) -> [FieldAction] {
        let shelf = FileShelf.shared
        func with(_ act: @escaping @MainActor (URL) -> Void) -> () -> Void {
            { Task { @MainActor in if let url = await shelf.fetch(one) { act(url) } } }
        }
        var out: [FieldAction] = [
            FieldAction(id: "open", title: "Open", symbol: "arrow.up.right", image: one.path.map { ActionIcons.app(opening: URL(fileURLWithPath: $0)) } ?? nil) {
                self.close()
                with { NSWorkspace.shared.open($0) }()
            },
            FieldAction(id: "copy", title: "Copy File", keys: Keymap.shared.text(.fieldCopy), symbol: "yab.copyframe.doc", group: 1) {
                self.close()
                with { url in
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.writeObjects([url as NSURL])
                }()
            },
        ]
        switch one.origin {
        case .mail(_, _, _, let from, _, _, let sent):
            if let thread = one.thread {
                out.append(FieldAction(id: "page", title: sent ? "Show the Mail" : "Show the Mail from \(ShelfFile.person(from))", keys: Keymap.shared.text(.fieldPage), symbol: "envelope", group: 1) {
                    self.close()
                    self.enterMail(thread)
                })
            }
        case .upload(let host):
            if let page = URL(string: "https://" + host) {
                out.append(FieldAction(id: "page", title: "Go to \(Browser.siteName(host))", keys: Keymap.shared.text(.fieldPage), symbol: "yab.page.left", group: 1, image: ActionIcons.site(page)) {
                    self.close()
                    self.open(page, foreground: true)
                })
            }
        }
        out.append(FieldAction(id: "reveal", title: "Show in Finder", keys: Keymap.shared.text(.fieldReveal), symbol: "yab.folder.search", group: 1, image: ActionIcons.finder()) {
            self.close()
            with { NSWorkspace.shared.activateFileViewerSelecting([$0]) }()
        })
        if let path = one.path {
            out.append(FieldAction(id: "second", title: "Copy Path", keys: Keymap.shared.text(.fieldSecond), symbol: "yab.copyframe.folder", group: 1) {
                self.copyPlain(path)
            })
        }
        if case .upload = one.origin {
            out.append(FieldAction(id: "delete", title: "Remove from List", keys: Keymap.shared.text(.fieldDelete), symbol: "xmark", group: 3) {
                shelf.forget(one)
                self.query.spot = min(self.query.spot, max(0, self.placeItems.count - 1))
            })
        }
        out.append(contentsOf: downloadsKit())
        return out
    }

    /// A purchase's: its site (a subscription's billing is there), Do It
    /// to stop one renewing, its mail, the carrier's page.
    private func purchaseActions(_ id: String) -> [FieldAction] {
        guard let item = Purchases.shared.item(id) else { return [] }
        let p = item.purchase
        var out: [FieldAction] = []
        if p.kind == .order, let track = Purchases.tracking(p) {
            out.append(FieldAction(id: "open", title: "Open \(p.carrier ?? "Carrier") Tracking", symbol: "shippingbox", image: ActionIcons.site(track)) {
                self.close()
                self.open(track, foreground: true)
            })
        }
        if let site = item.site {
            out.append(FieldAction(id: out.isEmpty ? "open" : "site", title: "Open \(Browser.siteName(site.host() ?? p.merchant))", symbol: "arrow.up.right",
                                   group: out.isEmpty ? 0 : 1, image: ActionIcons.site(site)) {
                self.close()
                self.open(site, foreground: true)
            })
        }
        if p.kind == .subscription, !p.canceled, Agents.ready {
            out.append(FieldAction(id: "hand", title: "Do It: Don’t Renew", keys: Keymap.shared.text(.fieldCopy), symbol: "agent.face", featured: true) {
                let hint = Purchases.hint(item, now: Date())
                guard let session = Agents.shared.task(Browser.doItWords(hint, now: Date()), context: [], on: nil, said: "Do It",
                                                       carrying: [Browser.handed(hint, now: Date()).label], name: "Don’t renew \(p.merchant)") else { return }
                Hints.shared.hand(hint.id, to: session.id)
                self.close()
            })
        }
        if let thread = item.thread {
            out.append(FieldAction(id: "page", title: p.kind == .order ? "Show the Mail" : "Show the Receipt", keys: Keymap.shared.text(.fieldPage), symbol: "envelope", group: 1) {
                self.close()
                self.enterMail(thread)
            })
        }
        if let price = item.price {
            out.append(FieldAction(id: "second", title: "Copy Amount", keys: Keymap.shared.text(.fieldSecond), symbol: "yab.copyframe.doc", group: 1) {
                self.copyPlain(price)
            })
        }
        if p.kind == .subscription, let host = p.host, !p.canceled {
            out.append(FieldAction(id: "quiet", title: "Ask Again Next Year", symbol: "clock", group: 3) {
                Purchases.shared.askNextYear(host)
            })
        }
        return out
    }

    /// The whole list's own: the folder, and clearing the list (files stay).
    private func downloadsKit() -> [FieldAction] {
        [FieldAction(id: "folder", title: "Open Downloads Folder", symbol: "yab.folder.down", group: 4, image: ActionIcons.file(currentDownloadFolder)) {
            self.close()
            NSWorkspace.shared.open(self.currentDownloadFolder)
        },
         FieldAction(id: "clear", title: "Clear List…", keys: Keymap.shared.text(.fieldClear), symbol: "trash", group: 4) {
            self.close()
            Task { @MainActor in
                let yes = await Questions.shared.ask(Question(
                    title: "Clear the list of downloads?", detail: "The files stay where they are, in the Finder.",
                    glyph: "arrow.down.circle", yes: "Clear List"
                ))
                if yes { self.loot.forgetAll() }
            }
        }]
    }

    private func fetchActions(_ fetch: Hoard.Fetch) -> [FieldAction] {
        var out: [FieldAction] = []
        if fetch.failed {
            out.append(FieldAction(id: "retry", title: fetch.paused ? "Resume" : "Try Again", symbol: fetch.paused ? "arrow.clockwise" : "yab.reload") { self.hoard.retry(fetch) })
        }
        if let page = downloadPages[fetch.id]?.url {
            out.append(FieldAction(id: "page", title: "Return to Page", keys: Keymap.shared.text(.fieldPage), symbol: "yab.page.left", group: 1, image: ActionIcons.site(page)) {
                self.close()
                self.open(page, foreground: true)
            })
        }
        out.append(FieldAction(id: "delete", title: fetch.failed ? "Remove from List" : "Cancel Download", keys: Keymap.shared.text(.fieldDelete), symbol: "xmark", group: 3) {
            if fetch.failed { self.hoard.dismiss(fetch) } else { self.hoard.cancel(fetch) }
        })
        out.append(contentsOf: downloadsKit())
        return out
    }

    /// The tab the box the caret was in is on, while it is still the page
    /// the field came up over.
    func formTab() -> (PageForm, Tab)? {
        guard let form = query.form, let tab = autofillTab(form.tab),
              Tab.originOf(tab.address) == form.origin else { return nil }
        return (form, tab)
    }

    /// Whether a login is the page's own: the same site, and not a page
    /// sent in the clear for one kept from https.
    private func loginFits(_ entry: Vault.Entry, _ form: PageForm, _ tab: Tab) -> Bool {
        guard !form.host.isEmpty, Vault.registrable(entry.host) == Vault.registrable(form.host) else { return false }
        if tab.address?.scheme?.lowercased() == "http" {
            return Vault.logins(for: entry.host).first { $0.user == entry.user }?.clear == true
        }
        return true
    }

    /// What ↩ does with a login where the caret was: into the password box
    /// it goes alone, the name typed kept; from the name box yab writes the
    /// name and the password both, as the list under the box does. Another
    /// site's never goes in.
    private enum LoginGoes { case pastes, fills, code, copies }

    private func loginGoes(_ entry: Vault.Entry) -> LoginGoes {
        guard let (form, tab) = formTab(), let box = form.box else { return .copies }
        guard loginFits(entry, form, tab) else { return .copies }
        if box.password { return .pastes }
        // A box asking for the site's one-time code, and the login has one.
        if Browser.asksCode(box), query.stock.codes.contains(entry.id) { return .code }
        if box.signIn || form.login != nil { return .fills }
        return .copies
    }

    /// Where ↩ will put the chosen row, for the field's end.
    var placeTarget: PlaceTarget? {
        if query.place == .files, let form = query.form, let file = form.file {
            let site = Browser.site(form.host)
            guard fileAnswer != nil, fileRequest?.tab == form.tab, formTab() != nil else {
                return PlaceTarget(what: "The page changed", host: "", refused: true)
            }
            let count = fileSelected.count
            let detail = file.multiple && count > 0 ? "\(count) file\(count == 1 ? "" : "s")" : site
            return PlaceTarget(what: file.label, host: detail)
        }
        guard let item = placeItem, let (form, _) = formTab(), let box = form.box else { return nil }
        let site = Browser.site(form.host)
        switch item.what {
        case .login(let entry):
            switch loginGoes(entry) {
            case .pastes: return PlaceTarget(what: "Password", host: site)
            case .fills: return PlaceTarget(what: "Sign-in", host: site)
            case .code: return PlaceTarget(what: box.label.isEmpty ? "Code" : box.label, host: site)
            case .copies:
                if Vault.registrable(entry.host) != Vault.registrable(form.host) {
                    return PlaceTarget(what: "\(Browser.site(entry.host))’s, not \(site)’s", host: "", refused: true)
                }
                return nil
            }
        case .address:
            if fillsWallet(.address) != nil { return PlaceTarget(what: box.label.isEmpty ? "Address" : box.label, host: site) }
            if !box.password { return PlaceTarget(what: box.label.isEmpty ? "Text" : box.label, host: site) }
            return nil
        case .card(let card):
            if !card.expired, fillsWallet(.card) != nil { return PlaceTarget(what: "Card", host: site) }
            return nil
        default:
            return nil
        }
    }

    private func loginActions(_ entry: Vault.Entry) -> [FieldAction] {
        var out: [FieldAction] = []
        let copy = FieldAction(id: "copy", title: "Copy Password", keys: Keymap.shared.text(.fieldCopy), symbol: "yab.copyframe.key", group: 1) {
            self.proveOwner("copy the password for \(entry.host)") {
                guard let password = Vault.password(host: entry.host, user: entry.user) else { return }
                self.copySecret(password)
            }
        }
        switch loginGoes(entry) {
        case .fills:
            if let (_, tab) = formTab() {
                out.append(FieldAction(id: "fill", title: "Fill Name and Password", symbol: "key") {
                    guard let password = Vault.password(host: entry.host, user: entry.user) else { return }
                    self.close()
                    self.handBack(to: tab)
                    tab.namedAccount(entry.user)
                    tab.fill(user: entry.user, password: password) { [weak self] filled in
                        switch filled {
                        case .filled: Vault.touch(Login(host: entry.host, user: entry.user, password: "", used: entry.used))
                        case .gone: self?.toaster.pop("The sign-in fields are gone", mark: "exclamationmark.triangle")
                        case .refused: break
                        case .unasked: self?.cantAskToFill()
                        }
                    }
                })
            }
        case .pastes:
            if let (form, tab) = formTab() {
                out.append(FieldAction(id: "fill", title: "Paste Password", symbol: "key") {
                    guard let password = Vault.password(host: entry.host, user: entry.user) else { return }
                    self.close()
                    Vault.proveToFill(on: form.host) { [weak self] proven in
                        guard proven == .yes else {
                            if proven == .cannot { self?.cantAskToFill() }
                            return
                        }
                        self?.type(password, into: tab, origin: form.origin)
                        Vault.touch(Login(host: entry.host, user: entry.user, password: "", used: entry.used))
                    }
                })
            }
        case .code:
            if let (form, tab) = formTab() {
                out.append(FieldAction(id: "fill", title: "Paste Code", symbol: "clock") {
                    self.close()
                    self.proveOwner("paste the code for \(entry.host)") {
                        guard let setup = OneTime.setup(host: entry.host, user: entry.user) else { return }
                        self.type(OneTime.code(setup).code, into: tab, origin: form.origin)
                    }
                })
            }
        case .copies:
            break
        }
        out.append(copy)
        out.append(FieldAction(id: "second", title: "Copy User Name", keys: Keymap.shared.text(.fieldSecond), symbol: "yab.copyframe.person", group: 1) {
            self.copyPlain(entry.user, transient: true)
        })
        if query.stock.codes.contains(entry.id) {
            out.append(FieldAction(id: "code", title: "Copy One-Time Code", keys: Keymap.shared.text(.fieldCode), symbol: "yab.copyframe.hash", group: 1) {
                self.proveOwner("copy the code for \(entry.host)") {
                    guard let setup = OneTime.setup(host: entry.host, user: entry.user) else { return }
                    self.copySecret(OneTime.code(setup).code)
                }
            })
        }
        out.append(FieldAction(id: "show", title: query.revealed?.id == "login." + entry.id ? "Hide Password" : "Show Password", keys: Keymap.shared.text(.fieldShow), symbol: query.revealed?.id == "login." + entry.id ? "eye.slash" : "yab.eye", group: 2) {
            if self.query.revealed?.id == "login." + entry.id {
                self.query.revealed = nil
                return
            }
            self.proveOwner("show the password for \(entry.host)") {
                guard let password = Vault.password(host: entry.host, user: entry.user) else { return }
                self.query.revealed = (id: "login." + entry.id, text: password)
            }
        })
        out.append(FieldAction(id: "edit", title: "Edit Login…", keys: Keymap.shared.text(.fieldEdit), symbol: "yab.key.pen", group: 2) {
            self.editPassword(entry)
        })
        out.append(FieldAction(id: "page", title: "Open \(entry.host)", keys: Keymap.shared.text(.fieldPage), symbol: "yab.arrowout", group: 2, image: ActionIcons.site(URL(string: "https://" + entry.host))) {
            guard let url = URL(string: "https://" + entry.host) else { return }
            self.close()
            self.open(url, foreground: true)
        })
        out.append(FieldAction(id: "change", title: "Change Password on \(Browser.site(entry.host))", symbol: "yab.globe.pen", group: 2) {
            // The address sites agree on; one without it sends you home.
            guard let url = URL(string: "https://" + entry.host + "/.well-known/change-password") else { return }
            self.close()
            self.open(url, foreground: true)
        })
        out.append(contentsOf: codeActions(entry))
        out.append(FieldAction(id: "delete", title: "Forget…", keys: Keymap.shared.text(.fieldDelete), symbol: "trash", group: 3) {
            self.forgetPasswords([entry], asking: Question(
                    title: "Forget the password for \(entry.host)?",
                    detail: "\(entry.user). It goes from this Mac’s keychain, with its one-time code. This can’t be undone.",
                    glyph: "trash", yes: "Forget", danger: true
            ))
        })
        if !Leaks.enabled {
            out.append(FieldAction(id: "leaks", title: "Check for Leaks…", symbol: "yab.shield.search", group: 4) {
                self.close()
                Task { @MainActor in
                    let yes = await Questions.shared.ask(Question(
                        title: "Check your passwords for leaks?",
                        detail: "Only the first 5 characters of each password’s hash go to haveibeenpwned.com, never a password.",
                        glyph: "exclamationmark.triangle", yes: "Check Now", no: "Not Now"
                    ))
                    guard yes else { return }
                    Leaks.enabled = true
                    Browser.leaks = nil
                    self.openPlace(.passwords)
                    self.weighPasswords()
                }
            })
        } else {
            out.append(FieldAction(id: "leaks", title: "Check for Leaks Again", symbol: "exclamationmark.triangle", group: 4) {
                Browser.leaks = nil
                self.query.stock.leaked = [:]
                self.query.acting = nil
                self.weighPasswords()
            })
        }
        out.append(FieldAction(id: "more", title: "Bring In More…", symbol: "tray.and.arrow.down", group: 4) { self.bringMore() })
        out.append(FieldAction(id: "export", title: "Export Passwords…", symbol: "arrow.up.forward", group: 4) { self.exportPasswords() })
        return out
    }

    /// Whether a card or an address can go into the box the caret was in.
    private func fillsWallet(_ group: WalletField.Group) -> Browser.WalletChoices? {
        guard let list = query.form?.wallet, list.group == group,
              let tab = autofillTab(list.tab), Tab.originOf(tab.address) == list.origin else { return nil }
        return list
    }

    private func cardActions(_ card: SavedCard) -> [FieldAction] {
        var out: [FieldAction] = []
        if !card.expired, let list = fillsWallet(.card) {
            out.append(FieldAction(id: "fill", title: "Fill Card", symbol: "creditcard") {
                self.walletList = Browser.WalletChoices(tab: list.tab, spot: list.spot, group: .card, cards: [card], addresses: [], origin: list.origin)
                self.chooseWallet(0)
            })
        }
        out.append(FieldAction(id: "copy", title: "Copy Card Number", keys: Keymap.shared.text(.fieldCopy), symbol: "yab.copyframe.card", group: 1) {
            // Wallet.prove asks every time, as a card on the page does.
            Wallet.prove("copy the number of \(card.title)") { proven in
                guard proven == .yes, let number = Wallet.number(of: card.id) else { return }
                self.putSecret(number)
            }
        })
        if card.keepsCode {
            out.append(FieldAction(id: "code", title: "Copy Security Code", symbol: "yab.copyframe.lock", group: 1) {
                Wallet.prove("copy the security code of \(card.title)") { proven in
                    guard proven == .yes, let code = Wallet.securityCode(of: card.id) else { return }
                    self.putSecret(code)
                }
            })
        }
        out.append(FieldAction(id: "second", title: "Copy Expiry", keys: Keymap.shared.text(.fieldSecond), symbol: "yab.copyframe.calendar", group: 1) {
            self.put(card.expiry, passing: true)
        })
        let addresses = query.stock.addresses
        if let billing = Wallet.billing(of: card, among: addresses) {
            out.append(FieldAction(id: "billing", title: "Copy Billing Address", symbol: "yab.copyframe.home", group: 1) {
                self.put(Browser.lines(of: billing), passing: true)
            })
        }
        // Another kept address to bill it to: one row each, as a list of
        // choices is in ⌘K.
        for other in addresses where other.id != Wallet.billing(of: card, among: addresses)?.id {
            out.append(FieldAction(id: "bill." + other.id, title: "Bill to \(other.title)", symbol: "house", group: 3) {
                DispatchQueue.global(qos: .userInitiated).async {
                    Wallet.update(card: card.id) { $0.billing = other.id }
                    let cards = Wallet.cards()
                    DispatchQueue.main.async { self.query.stock.cards = cards }
                }
            })
        }
        out.append(FieldAction(id: "show", title: query.revealed?.id == "card." + card.id ? "Hide Number" : "Show Number", keys: Keymap.shared.text(.fieldShow), symbol: query.revealed?.id == "card." + card.id ? "eye.slash" : "yab.eye", group: 2) {
            if self.query.revealed?.id == "card." + card.id {
                self.query.revealed = nil
                return
            }
            Wallet.prove("show the number of \(card.title)") { proven in
                guard proven == .yes, let number = Wallet.number(of: card.id) else { return }
                self.query.revealed = (id: "card." + card.id, text: Browser.grouped(number))
            }
        })
        out.append(FieldAction(id: "edit", title: "Edit Card", keys: Keymap.shared.text(.fieldEdit), symbol: "pencil", group: 2) { self.beginEdit(.card(card.id)) })
        out.append(FieldAction(id: "delete", title: "Forget…", keys: Keymap.shared.text(.fieldDelete), symbol: "trash", group: 3) {
            self.close()
            Task { @MainActor in
                let yes = await Questions.shared.ask(Question(
                    title: "Forget \(card.title)?",
                    detail: "It goes from this Mac’s keychain. This can’t be undone.",
                    glyph: "trash", yes: "Forget", danger: true
                ))
                if yes { Wallet.forget(card: card.id) }
            }
        })
        out.append(contentsOf: walletKit())
        return out
    }

    private func addressActions(_ address: StreetAddress) -> [FieldAction] {
        var out: [FieldAction] = []
        let whole = Browser.lines(of: address)
        if let list = fillsWallet(.address) {
            out.append(FieldAction(id: "fill", title: "Fill Address", symbol: "house") {
                self.close()
                if let tab = self.autofillTab(list.tab) { self.handBack(to: tab) }
                self.walletList = Browser.WalletChoices(tab: list.tab, spot: list.spot, group: .address, cards: [], addresses: [address], origin: list.origin)
                self.chooseWallet(0)
            })
        }
        if out.isEmpty, let (form, tab) = formTab(), let box = form.box, !box.password {
            out.append(FieldAction(id: "fill", title: "Paste Address", symbol: "house") {
                self.close()
                self.type(box.lines ? whole : whole.replacingOccurrences(of: "\n", with: ", "), into: tab, origin: form.origin)
            })
        }
        out.append(FieldAction(id: "copy", title: "Copy Address", keys: Keymap.shared.text(.fieldCopy), symbol: "doc.on.doc", group: 1) {
            self.copyPlain(whole, transient: true)
        })
        out.append(FieldAction(id: "second", title: "Copy on One Line", keys: Keymap.shared.text(.fieldSecond), symbol: "yab.copyframe.text", group: 1) {
            self.copyPlain(whole.replacingOccurrences(of: "\n", with: ", "), transient: true)
        })
        out.append(FieldAction(id: "edit", title: "Edit Address", keys: Keymap.shared.text(.fieldEdit), symbol: "pencil", group: 2) { self.beginEdit(.address(address.id)) })
        out.append(FieldAction(id: "delete", title: "Forget…", keys: Keymap.shared.text(.fieldDelete), symbol: "trash", group: 3) {
            self.close()
            Task { @MainActor in
                let yes = await Questions.shared.ask(Question(
                    title: "Forget \(address.title)?",
                    detail: "It goes from this Mac’s keychain. This can’t be undone.",
                    glyph: "trash", yes: "Forget", danger: true
                ))
                if yes { Wallet.forget(address: address.id) }
            }
        })
        out.append(contentsOf: walletKit())
        return out
    }

    private func visitActions(_ url: URL, title: String, key: String) -> [FieldAction] {
        let asking = self.asking
        let goes = query.stock.jumps[key] ?? url
        var out = [FieldAction(id: "open", title: self.openWords(asking), symbol: self.openSymbol(asking), image: ActionIcons.site(goes)) {
            self.close()
            self.place(goes, asking, from: self.active)
        }]
        out.append(FieldAction(id: "copy", title: "Copy URL", keys: Keymap.shared.text(.fieldCopy), symbol: "link", group: 1) {
            self.copyPlain(url.absoluteString)
        })
        out.append(FieldAction(id: "second", title: "Copy Markdown Link", keys: Keymap.shared.text(.fieldSecond), symbol: "markdown", group: 1) {
            self.copyPlain("[\(title)](\(url.absoluteString))")
        })
        out.append(FieldAction(id: "plain", title: "Open in Background Tab", keys: Keymap.shared.text(.fieldAlternate), symbol: "yab.tab.down", group: 1) {
            self.close()
            self.open(url, foreground: false, from: self.active)
        })
        // Deleted, in the red of what goes for
        // good; ⌘ or ⇧ picks more rows for one Delete (PlacePicks).
        out.append(FieldAction(id: "delete", title: "Delete from History", keys: Keymap.shared.text(.fieldDelete), symbol: "yab.page.trash", group: 3, danger: true) {
            Diary.shared.forget(keys: [key]) { [weak self] in self?.askHistory() }
            // The address field's history keeps a page by its key.
            self.history.forget(History.key(for: url))
        })
        if let host = url.host() {
            out.append(FieldAction(id: "forgetsite", title: "Delete All from \(Browser.site(host))…", symbol: "yab.globe.trash", group: 3, danger: true) {
                self.close()
                Task { @MainActor in
                    let yes = await Questions.shared.ask(Question(
                        title: "Delete all history from \(Browser.site(host))?",
                        detail: "Every page of it you have visited. This can’t be undone.",
                        glyph: "trash", yes: "Delete", danger: true
                    ))
                    guard yes else { return }
                    // From the address field's suggestions too, page by page.
                    Diary.shared.forget(host: host) { [weak self] urls in
                        urls.forEach { self?.history.forget(History.key(for: $0)) }
                    }
                }
            })
            out.append(onlySite(host, .history))
        }
        for (index, name) in ["the Last Hour", "Today", "Today and Yesterday", "All Time"].enumerated() {
            out.append(FieldAction(id: "recent\(index)", title: "Forget \(name)…", symbol: "yab.clock.trash", group: 4) { self.forgetRecent(index) })
        }
        out.append(FieldAction(id: "export", title: "Export History…", symbol: "yab.clock.up", group: 5) { self.exportHistory() })
        return out
    }

    /// Its chat first, where its runs are; run it, change it, set another.
    private func routineActions(_ id: String) -> [FieldAction] {
        guard let routine = Routines.shared.all.first(where: { $0.id == id }) else { return [] }
        let icon = FieldPlace.routines.symbol
        var out: [FieldAction] = []
        if let chat = routine.chat, Chats.shared.chat(chat) != nil {
            out.append(FieldAction(id: "open", title: "Open Chat", symbol: "yab.chat.right") {
                self.close()
                self.keepChat(chat)
                self.showChat(chat)
            })
        }
        if Agents.shared.session(routine.session)?.state.live != true {
            out.append(FieldAction(id: "run", title: "Run Now", symbol: "play", group: 1) {
                self.close()
                Routines.shared.run(routine)
            })
        }
        if routine.quiet != true {
            out.append(FieldAction(id: "edit", title: "Edit Routine…", keys: Keymap.shared.text(.fieldEdit), symbol: "yab.clock.pen", group: 1) {
                self.close()
                SettingsWindow.shared.showRoutine(routine, for: self)
            })
            out.append(FieldAction(id: "turn", title: routine.off == true ? "Turn On" : "Turn Off", symbol: icon, group: 2) {
                Routines.shared.turn(routine.id, on: routine.off == true)
            })
        }
        out.append(FieldAction(id: "new", title: "New Routine…", keys: Keymap.shared.text(.fieldNew), symbol: "plus", group: 2) {
            self.close()
            SettingsWindow.shared.showRoutine(nil, for: self)
        })
        out.append(FieldAction(id: "delete", title: "Delete Routine", keys: Keymap.shared.text(.fieldDelete), symbol: "trash", group: 3) {
            _ = Routines.shared.remove(routine.id)
            self.query.spot = min(self.query.spot, max(0, Routines.shared.all.count - 1))
        })
        return out
    }

    /// A project: ↩ opens it in the column, ⌘↩ asks in it, its field there
    /// ready (the place's ⌘↩, which copies elsewhere, has nothing to copy here).
    func projectActions(_ id: String) -> [FieldAction] {
        guard let project = chatProjects.project(id) else { return [] }
        return [
            FieldAction(id: "open", title: "Open Project", symbol: "folder") {
                self.close()
                self.openProject(project.id)
            },
            FieldAction(id: "copy", title: "Ask in Project", keys: Keymap.shared.text(.fieldCopy), symbol: "square.and.pencil", group: 1) {
                self.close()
                self.newChat(in: project.id)
            },
            FieldAction(id: "keep", title: project.pinned ? "Unpin Project" : "Pin Project", symbol: project.pinned ? "pin.slash" : "pin", group: 2) {
                self.chatProjects.pin(project.id, !project.pinned)
            },
        ]
    }

    private func chatActions(_ id: String) -> [FieldAction] {
        guard let chat = Chats.shared.chat(id) else { return [] }
        var out = [FieldAction(id: "open", title: "Show Chat", symbol: FieldAnswer.mark(chat.cli)) {
            self.close()
            // Kept in the column until another is picked or it is unpinned.
            self.keepChat(chat.id)
            self.showChat(chat.id)
        }]
        if !chat.answer.isEmpty {
            out.append(FieldAction(id: "copy", title: "Copy Answer", keys: Keymap.shared.text(.fieldCopy), symbol: "yab.copyframe.text", group: 1) {
                self.copyPlain(chat.answer)
            })
        }
        out.append(FieldAction(id: "keep", title: chat.pinned ? "Unpin Chat" : "Pin Chat", symbol: chat.pinned ? "pin.slash" : "pin", group: 2) {
            Chats.shared.pin(chat.id, !chat.pinned)
        })
        // One still working is stopped first, in its column.
        if Agents.shared.session(chat.id)?.state.live != true {
            out.append(FieldAction(id: "delete", title: "Delete Chat", keys: Keymap.shared.text(.fieldDelete), symbol: "trash", group: 3) {
                self.deleteChat(chat.id)
                self.query.spot = min(self.query.spot, max(0, Chats.shared.all.count - 1))
            })
        }
        return out
    }

    // MARK: copying

    /// On the clipboard as words, the box put away and nothing said: the
    /// box going is the answer. A
    /// user name or an address is marked passing, so it doesn't settle in
    /// the clipboard's history.
    func copyPlain(_ text: String, transient: Bool = false) {
        close()
        put(text, passing: transient)
    }

    /// Words on the clipboard, the box left as it is.
    func put(_ text: String, passing: Bool = false) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        if passing { board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) }
    }

    /// A secret on the clipboard: on this Mac only, marked the way clipboard
    /// keepers agree means "don't keep, don't show", and taken off again a
    /// minute later unless something else was copied since, as the
    /// the passwords page copied before the place.
    func copySecret(_ text: String) {
        close()
        putSecret(text)
    }

    /// A secret on the clipboard, the box left as it is.
    func putSecret(_ text: String) {
        let board = NSPasteboard.general
        board.prepareForNewContents(with: .currentHostOnly)
        board.setString(text, forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let count = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard board.changeCount == count else { return }
            board.clearContents()
        }
    }

    /// Touch ID before a password or a code leaves the keychain, once in
    /// five minutes, as the passwords page asks. A test run answers itself
    /// (Wallet.benchAnswer).
    func proveOwner(_ reason: String, otherwise refused: (() -> Void)? = nil, _ then: @escaping () -> Void) {
        if let at = Browser.placeProven, Date().timeIntervalSince(at) < Vault.grace {
            then()
            return
        }
        Wallet.prove(reason) { proven in
            guard proven == .yes else { refused?(); return }
            Browser.placeProven = Date()
            then()
        }
    }

    @MainActor static var placeProven: Date?

    /// Words typed into the box the caret is in, as the keyboard would: the
    /// page gets the keyboard back first, and only the page the field came
    /// up over takes them.
    func type(_ text: String, into tab: Tab, origin: String) {
        guard let web = tab.builtPage else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard Tab.originOf(tab.address) == origin else { return }
            web.window?.makeFirstResponder(web)
            web.call("document.execCommand('insertText', false, text)", arguments: ["text": text], in: .page) { _ in }
        }
    }

    /// The page gets the keyboard back, with the caret where it was.
    func handBack(to tab: Tab) {
        guard let web = tab.builtPage else { return }
        let outsidePage = outside.contains { $0.id == tab.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if outsidePage { web.window?.makeKeyAndOrderFront(nil) }
            web.window?.makeFirstResponder(web)
        }
    }

    /// A card's number in fours.
    static func grouped(_ number: String) -> String {
        let digits = number.filter(\.isNumber)
        return stride(from: 0, to: digits.count, by: 4).map { start in
            let from = digits.index(digits.startIndex, offsetBy: start)
            let to = digits.index(from, offsetBy: min(4, digits.count - start))
            return String(digits[from..<to])
        }.joined(separator: " ")
    }

    /// An address as it is written on an envelope.
    static func lines(of address: StreetAddress) -> String {
        let city = [address.city, [address.region, address.postal].filter { !$0.isEmpty }.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: ", ")
        return [address.name, address.organization, address.street, city, address.country].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A place's own keys, besides ↩ and ⌘↩ (see the top of this file).
    func placeKey(_ event: NSEvent) -> Bool {
        guard let place = query.place, place != .clipboard, place != .emoji else { return false }
        let map = Keymap.shared
        if map.matches(event, .fieldFilter) {
            if place == .files { return cycleFileFolder() }
            let count = place.filters.count
            guard count > 1 else { return false }
            query.placeFilter = (query.placeFilter + 1) % count
            query.spot = 0
            if place == .history {
                query.stock.threadPages = nil
                askHistory()
            }
            return true
        }
        if map.matches(event, .fieldPage) { return runAction("page") }
        if map.matches(event, .fieldSecond) { return runAction("second") }
        if map.matches(event, .fieldReveal) { return runAction("reveal") }
        if map.matches(event, .fieldCode) { return runAction("code") }
        if map.matches(event, .fieldShow), place == .passwords || place == .autofill { return runAction("show") }
        if map.matches(event, .fieldEdit) { return runAction("edit") }
        if map.matches(event, .fieldNew), place == .autofill {
            beginEdit(.card(nil))
            return true
        }
        if map.matches(event, .fieldNew), place == .snippets {
            beginEdit(.snippet(nil))
            return true
        }
        if map.matches(event, .fieldNew), place == .routines {
            close()
            SettingsWindow.shared.showRoutine(nil, for: self)
            return true
        }
        if map.matches(event, .fieldNew), place == .bookmarks {
            newBookmarkFolder()
            return true
        }
        if map.matches(event, .fieldDelete) { return runAction("delete") }
        if map.matches(event, .fieldClear) { return runAction("clear") }
        return false
    }
}

extension Browser {
    /// Where a downloaded file came from, written on it: the file's address, then the page's. The Finder's Get Info shows
    /// it, and a file dropped back in knows its page.
    nonisolated static func writeWhereFrom(_ file: URL, _ sources: [URL]) {
        guard !sources.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: sources.map(\.absoluteString), format: .binary, options: 0)
        else { return }
        _ = file.withUnsafeFileSystemRepresentation { path in
            data.withUnsafeBytes { bytes in
                setxattr(path, "com.apple.metadata:kMDItemWhereFroms", bytes.baseAddress, data.count, 0, 0)
            }
        }
    }
}

/// The icons of things outside the app that an action goes to, as a
/// launcher's actions wear them: the app a file opens in, the Finder, a
/// folder as the Finder draws it, a site's own icon. An app's or a
/// folder's is read once and kept; a site's comes from what Favicons has.
@MainActor
enum ActionIcons {
    private static var kept: [String: NSImage] = [:]

    private static func keep(_ key: String, _ make: () -> NSImage?) -> NSImage? {
        if let hit = kept[key] { return hit }
        guard let image = make() else { return nil }
        kept[key] = image
        return image
    }

    /// The app this file opens in, Preview for a picture.
    static func app(opening file: URL) -> NSImage? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: file) else { return nil }
        return keep("app:" + app.path) { NSWorkspace.shared.icon(forFile: app.path) }
    }

    static func finder() -> NSImage? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { return nil }
        return keep("app:" + app.path) { NSWorkspace.shared.icon(forFile: app.path) }
    }

    /// A folder or a file as the Finder draws it: the Downloads folder
    /// with its arrow.
    static func file(_ url: URL) -> NSImage? {
        keep("file:" + url.path) { NSWorkspace.shared.icon(forFile: url.path) }
    }

    /// Whether an icon is drawn in dark ink, a black GitHub cat: on a dark
    /// box it goes onto a light plate, or it would not be seen. Worked out
    /// once an icon, from its pixels at 8 by 8, weighing each by how opaque.
    static func inky(_ image: NSImage) -> Bool {
        let key = ObjectIdentifier(image)
        if let hit = dark[key] { return hit }
        var answer = false
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let side = 8
            var bytes = [UInt8](repeating: 0, count: side * side * 4)
            if let context = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
                var light = 0.0, weight = 0.0
                for i in stride(from: 0, to: bytes.count, by: 4) {
                    let a = Double(bytes[i + 3]) / 255
                    guard a > 0.1 else { continue }
                    let r = Double(bytes[i]) / 255 / a, g = Double(bytes[i + 1]) / 255 / a, b = Double(bytes[i + 2]) / 255 / a
                    light += (0.2126 * r + 0.7152 * g + 0.0722 * b) * a
                    weight += a
                }
                answer = weight > 0 && light / weight < 0.25
            }
        }
        dark[key] = answer
        return answer
    }

    private static var dark: [ObjectIdentifier: Bool] = [:]

    /// A site's own icon, if it has been fetched.
    static func site(_ url: URL?) -> NSImage? {
        guard let url, let host = url.host()?.lowercased() else { return nil }
        // A port's own site has its own icon, and none of the host's.
        if let site = Favicons.site(url), site != host { return Favicons.shared.cached(site) }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return Favicons.shared.cached(host) ?? Favicons.shared.cached(bare) ?? Favicons.shared.cached("www." + bare)
    }
}
