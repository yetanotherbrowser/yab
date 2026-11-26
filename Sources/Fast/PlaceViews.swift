import SwiftUI
import AppKit
import MailCore
import QuickLookThumbnailing

// The places' list and what the chosen row is, as Clipboard History has
// them (ClipPlace): rows on the left, each with where it came from under
// its name; on the right the chosen one and what is known of it.

/// Downloads, Passwords, Cards and Addresses, or History: the list, and
/// beside it the chosen row.
struct PlaceView: View {
    let browser: Browser
    @ObservedObject var query: Query
    let place: FieldPlace
    var height: CGFloat = Omnibox.placeHeight
    @ObservedObject private var loot: Loot
    @ObservedObject private var hoard: Hoard

    init(browser: Browser, query: Query, place: FieldPlace, height: CGFloat) {
        self.browser = browser
        self.query = query
        self.place = place
        self.height = height
        loot = browser.loot
        hoard = browser.hoard
    }

    var body: some View {
        let list = browser.placeItems
        let chosen = list.indices.contains(query.spot) ? list[query.spot] : nil
        Group {
            if let empty = browser.placeEmpty {
                PlaceEmptyView(browser: browser, query: query, empty: empty)
                    .belowField()
                    .frame(height: height)
            } else {
                split(list, chosen)
            }
        }
        // Chats change as their agents work: the rows made again, only here.
        .onReceive(Chats.shared.$all.dropFirst()) { _ in
            if place == .chats || place == .routines { query.stock.version += 1 }
        }
        .onReceive(Routines.shared.$all.dropFirst()) { _ in
            if place == .routines { query.stock.version += 1 }
        }
        .onReceive(MailSnippets.shared.$all.dropFirst()) { _ in
            if place == .snippets { query.stock.version += 1 }
        }
        // A thread named, renamed or forgotten: By Thread asks again.
        .onReceive(NotificationCenter.default.publisher(for: Diary.threadsChanged)) { _ in
            if place == .history, query.placeFilter == FieldPlace.byThread { browser.askHistory() }
        }
    }

    private func split(_ list: [PlaceItem], _ chosen: PlaceItem?) -> some View {
        HStack(spacing: 0) {
            rows(list)
                .frame(width: 320)
            Rectangle()
                .fill(Omnibox.seam)
                .frame(width: 1)
                .belowField()
            PlacePreview(browser: browser, query: query, item: chosen)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .belowField()
        }
        .frame(height: height)
    }

    private func rows(_ list: [PlaceItem]) -> some View {
        // Two or more picked are all lit; one is the plain chosen row.
        let picked = query.picks.count > 1 ? query.picks : []
        return ScrollViewReader { reader in
            ThreadScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if list.isEmpty {
                        Text(empty)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Palette.muted)
                            .padding(12)
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 0) {
                            if index == 0 || list[index - 1].section != item.section {
                                Text(item.section)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.muted)
                                    .padding(.horizontal, Omnibox.gutter - Omnibox.inset)
                                    .padding(.top, index == 0 ? 4 : 12)
                                    .padding(.bottom, 6)
                            }
                            draggable(row(item, chosen: index == query.spot || picked.contains(item.id)), item: item)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { choose(index); _ = browser.runPrimary() }
                                // ⌘ and ⇧ pick rows together (PlacePicks).
                                .onTapGesture { if !browser.pickClick(index, flags: NSEvent.modifierFlags) { choose(index) } }
                                // A right-click: its actions, as ⌘K has them; on
                                // a picked row, the picks' one act.
                                .overlay { FieldRowMenu(name: "place \(index)") { browser.showActions(forPlaceRow: index) } }
                                .onAppear {
                                    // History goes on as its end comes into view.
                                    if place == .history, index >= list.count - 12 { browser.askHistory(more: true) }
                                }
                        }
                    }
                }
                .padding(Omnibox.inset)
            }
            .edgeScroll()
            .onChange(of: query.spot) { _, spot in
                if list.indices.contains(spot) { reader.scrollTo(list[spot].id) }
            }
        }
    }

    /// Only files have a drag payload. Avoid native drag handlers on every
    /// history or account row, where a drag previously returned nothing.
    @ViewBuilder
    private func draggable<Row: View>(_ row: Row, item: PlaceItem) -> some View {
        switch item.what {
        case .kept, .file: row.onDrag { dragged(item) }
        case .shelf(let one) where one.path != nil: row.onDrag { dragged(item) }
        case .bookmark(let node) where !node.isFolder: row.onDrag { dragged(item) }
        default: row
        }
    }

    /// Another row taken while one is written: the writing goes, as esc.
    private func choose(_ index: Int) {
        if query.edit != nil, index != query.spot { browser.cancelEdit() }
        query.unpick()
        query.spot = index
    }

    /// A download dragged out of its row is the file itself, for the
    /// Finder, a message or a page's box.
    private func dragged(_ item: PlaceItem) -> NSItemProvider {
        let url: URL
        switch item.what {
        case .kept(let keep): url = keep.url
        case .file(let file): url = file
        case .shelf(let one): url = URL(fileURLWithPath: one.path ?? "")
        case .bookmark(let node):
            // A site kept goes out as its address, for a tab strip or a page.
            guard let link = node.url.flatMap(URL.init(string:)) else { return NSItemProvider() }
            return NSItemProvider(object: link as NSURL)
        default: return NSItemProvider()
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return NSItemProvider() }
        return NSItemProvider.file(url)
    }

    /// What the list says with nothing in it.
    private var empty: String {
        let searching = !query.typed.isEmpty
        switch place {
        case .files: return searching ? "No file says that" : "Nothing new " + RecentFiles.phrase(of: RecentFiles.folders, joined: "or")
        case .downloads: return searching ? "No download says that" : "What you download comes here"
        case .passwords: return searching ? "No password for that" : "Passwords you save come here"
        case .autofill: return searching ? "Nothing kept says that" : "Cards and addresses you save come here"
        case .history: return searching ? "Nothing visited says that" : "Pages you visit come here"
        case .bookmarks: return searching ? "No bookmark says that" : "Pages you keep come here"
        case .chats: return searching ? "No chat says that" : "Your chats with agents come here"
        case .routines: return searching ? "No routine says that" : "Your routines come here"
        case .snippets: return searching ? "No snippet says that" : "Your snippets come here"
        default: return ""
        }
    }

    private func row(_ item: PlaceItem, chosen: Bool) -> some View {
        HStack(spacing: Omnibox.gap) {
            PlaceTileView(tile: item.tile, meter: browser.hoard.meter)
            if place == .files, browser.query.form?.file?.multiple == true {
                Image(systemName: browser.fileSelected.contains(String(item.id.dropFirst(5))) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(marked(item.title))
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        // A thread's name reads from its start; a page's keeps its site at the end.
                        .truncationMode(item.what.isThread ? .tail : .middle)
                    if let tag = item.tag {
                        // Words over marks: what needs a look, said.
                        let tint: Color? = item.alarm ? Color(nsColor: .systemOrange) : item.fresh ? .accentColor : nil
                        Text(tag)
                            .font(.system(size: 11))
                            .foregroundStyle(tint ?? Palette.muted)
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                                .fill(tint?.opacity(0.14) ?? Omnibox.tileFill))
                            .fixedSize()
                    }
                }
                if case .fetch(let fetch) = item.what, !fetch.failed {
                    // Live, as the downloads list says it: the row is built once.
                    HoardFetchWords(meter: browser.hoard.meter, fetch: fetch)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if case .profile = item.what {
                    ProfileSource(browser: browser, fallback: item.source)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if !item.source.isEmpty {
                    Text(marked(item.source))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(item.faded ? 0.55 : 1)
        .padding(.horizontal, Omnibox.gutter - Omnibox.inset)
        .frame(height: item.source.isEmpty ? Omnibox.rowHeight : Omnibox.rowHeight + 8)
        .background {
            if chosen {
                RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Omnibox.chosenFill)
            }
        }
        .transaction { $0.animation = nil }
    }

    /// The words searched for, lit where History found them.
    private func marked(_ text: String) -> AttributedString {
        PlaceView.marked(text, words: place == .history || place == .bookmarks || place == .chats || place == .routines ? query.typed : "")
    }

    static func marked(_ text: String, words: String) -> AttributedString {
        var out = AttributedString(text)
        for word in words.lowercased().split(separator: " ") where word.count >= 2 && !word.contains(":") {
            var from = out.startIndex
            while from < out.endIndex, let found = out[from...].range(of: word, options: .caseInsensitive) {
                out[found].backgroundColor = Color(nsColor: .systemYellow).opacity(0.35)
                from = found.upperBound
            }
        }
        return out
    }
}

/// A place's row's mark: the site's icon, the file's, one of the app's on
/// its tile, or a download's ring filling as it comes.
struct PlaceTileView: View {
    let tile: PlaceTile
    @ObservedObject var meter: Hoard.Meter

    var body: some View {
        switch tile {
        case .site(let host):
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            Mark(icon: Self.picture(tile),
                 letter: bare.first.map { String($0).uppercased() } ?? "", size: Omnibox.tile - 4)
                .frame(width: Omnibox.tile, height: Omnibox.tile)
        case .page(let url):
            PlacePageMark(url: url)
        case .stack(let hosts):
            ThreadStack(hosts: hosts)
        case .file(let path):
            PlaceFileTile(path: path)
        case .symbol(let name):
            FieldMark(symbol: name)
        case .fetch(let fetch):
            HoardFetchIcon(meter: meter, fetch: fetch)
                .frame(width: Omnibox.tile, height: Omnibox.tile)
        case .pay(let brand):
            PayMark(kind: brand, height: 15)
                .frame(width: Omnibox.tile + 4, height: Omnibox.tile)
        case .hint(let id):
            HintMark(hint: Hints.shared.row(id))
        case .project(let id):
            if let project = Projects.shared.project(id) {
                ProjectCircle(project: project, size: Omnibox.tile)
            }
        }
    }
}

extension PlaceTileView {
    /// The site's or page's icon a row's tile draws, nil for a letter or
    /// any other kind of tile (also the bench's, evals/bookmark-icons).
    @MainActor static func picture(_ tile: PlaceTile) -> NSImage? {
        switch tile {
        case .site(let host):
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return Favicons.shared.cached(host) ?? Favicons.shared.cached(bare)
        case .page(let url):
            return PlacePageMark.known(url)
        default:
            return nil
        }
    }
}

/// A bookmark's mark in its row, the
/// page's favicon beside its title: the icon the page last wore, its
/// site's for one never open here (Favicons.cached(page:)). With neither
/// kept, as for bookmarks brought from another browser and never opened,
/// the site's letter, and its icon fetched once from its front page, as
/// the bookmarks' row does, put on as it arrives.
struct PlacePageMark: View {
    let url: URL
    /// The icon that arrived while it was shown, and for which address: a
    /// bookmark edited to another doesn't keep the old one's.
    @State private var arrived: (url: URL, icon: NSImage?)?

    var body: some View {
        let host = url.host()?.lowercased() ?? ""
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let icon = arrived?.url == url ? arrived?.icon : nil
        Mark(icon: icon ?? Self.known(url), letter: bare.first.map { String($0).uppercased() } ?? "", size: Omnibox.tile - 4)
            .frame(width: Omnibox.tile, height: Omnibox.tile)
            .onReceive(Favicons.shared.changes) { site in
                if site == Favicons.site(url) { arrived = (url, Self.known(url)) }
            }
            .onAppear {
                if Self.known(url) == nil { Favicons.shared.fetch(page: url) }
            }
    }

    /// What is kept for it, nothing fetched: the page's own icon, its
    /// site's (with its port), or the site's without www.
    @MainActor static func known(_ url: URL) -> NSImage? {
        if let icon = Favicons.shared.cached(page: url) { return icon }
        guard let host = url.host()?.lowercased(), host.hasPrefix("www.") else { return nil }
        return Favicons.shared.cached(String(host.dropFirst(4)))
    }
}

/// The chosen row of a place, whole, and what is known of it, a line
/// each. The preview and its lines scroll together, apart from the list;
/// a picture is kept to 190 points so the lines start on the first screen.
struct PlacePreview: View {
    let browser: Browser
    @ObservedObject var query: Query
    let item: PlaceItem?

    var body: some View {
        if let item, query.edit == nil, case .snippet(let id) = item.what, let snippet = MailSnippets.shared.snippet(id) {
            snippetPreview(snippet, item: item)
        } else if let item {
            // One scroll view for every row chosen, back at its top for each:
            // a new one a step, as .id would make, is a new NSScrollView.
            ScrollViewReader { reader in
            ThreadScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    Color.clear.frame(height: 0).id(PlacePreview.top)
                    if let edit = query.edit, !edit.inPlace {
                        if let editor = edit.passwordEditor {
                            PasswordEditForm(model: editor.model, save: { browser.saveEdit() }, cancel: { browser.cancelEdit() })
                        } else {
                            EditForm(browser: browser, query: query, edit: edit)
                        }
                    } else {
                    head(item)
                    let lines = facts(item)
                    if !lines.isEmpty {
                        // A thread's lines are what you did there; anything else's, what it is.
                        Text(item.what.isThread ? "What you did" : "Information")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 8)
                        VStack(spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, fact in
                                if fact.editing {
                                    CodeEditLine(browser: browser, query: query)
                                } else {
                                    FactLine(fact: fact, browser: browser)
                                }
                                if index < lines.count - 1 {
                                    Rectangle().fill(Omnibox.seam).frame(height: 0.5).padding(.horizontal, 8)
                                }
                            }
                        }
                    }
                    }
                }
                .padding(16)
            }
            .edgeScroll()
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: item.id) { _, _ in reader.scrollTo(PlacePreview.top, anchor: .top) }
            // ⇥ to a field below the fold brings it up.
            .onChange(of: query.edit?.focus) { _, focus in
                if let focus { withAnimation(Motion.arrive) { reader.scrollTo("edit.\(focus)") } }
            }
            }
        } else {
            Color.clear
        }
    }

    /// A snippet: its words filling the top, scrolled
    /// on their own when long, and Information held at the foot, its lines
    /// on a wash every other one.
    private func snippetPreview(_ snippet: MailSnippet, item: PlaceItem) -> some View {
        let lines = facts(item)
        return VStack(alignment: .leading, spacing: 0) {
            ThreadScrollView(.vertical) {
                snippetHead(snippet, item: item)
                    .padding(16)
            }
            .edgeScroll()
            .scrollBounceBehavior(.basedOnSize)
            .id(item.id)
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                Text("Information")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 8)
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, fact in
                        FactLine(fact: fact, browser: browser, height: 30)
                            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(index % 2 == 0 ? Omnibox.tileFill : .clear))
                    }
                }
            }
            .padding(.horizontal, 16)
            // Clear of the field's foot, which floats over the preview.
            .padding(.bottom, FieldFoot.room + 4)
        }
    }

    /// The top of the preview: the thing itself, as big as it reads.
    @ViewBuilder
    private func head(_ item: PlaceItem) -> some View {
        switch item.what {
        case .file(let url):
            VStack(spacing: 8) {
                FilePicture(path: url.path, side: 190)
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .opacity(item.faded ? 0.5 : 1)
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                if item.faded { Text("Moved or deleted").foregroundStyle(Palette.muted) }
            }
        case .kept(let keep):
            VStack(spacing: 8) {
                FilePicture(path: keep.path, side: 190)
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .opacity(item.faded ? 0.5 : 1)
                Text(keep.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if item.faded {
                    Text("Moved or deleted")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            }
            .frame(maxWidth: .infinity)
        case .shelf(let one):
            VStack(spacing: 8) {
                FilePicture(path: one.path ?? one.name, side: 190)
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                Text(one.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        case .fetch(let fetch):
            VStack(spacing: 8) {
                HoardFetchIcon(meter: browser.hoard.meter, fetch: fetch, side: 64)
                    .frame(width: 64, height: 76)
                Text(fetch.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Group {
                    if fetch.paused { Text("Paused") } else if fetch.failed { Text("Couldn’t download") } else { HoardFetchWords(meter: browser.hoard.meter, fetch: fetch) }
                }
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity)
        case .login(let entry):
            HStack(spacing: 12) {
                PlaceTileView(tile: .site(entry.host), meter: browser.hoard.meter)
                    .scaleEffect(1.6)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.host)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(entry.user)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                }
            }
            if let warning = browser.warning(for: entry) {
                self.warning(warning)
            }
        case .card(let card):
            CardDetail(browser: browser, query: query, card: card, faded: item.faded)
            if card.expired || card.soon != nil {
                warning(card.expired ? "Expired in \(card.expiry). Edit it when the new card comes: the number often stays the same."
                                     : "\(card.soon ?? ""). Edit it when the new card comes: the number often stays the same.")
            }
        case .address, .draft:
            EmptyView()
        case .profile:
            profileHead
        case .bring:
            bringHead
        case .bookmark(let node):
            if let url = node.url.flatMap(URL.init(string:)) {
                VisitPicture(key: Diary.key(url), url: url, on: browser.prefs.diaryText)
            }
            HStack(spacing: 12) {
                PlaceTileView(tile: item.tile, meter: browser.hoard.meter)
                    .scaleEffect(1.6)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                    Text(node.isFolder ? Bookmarks.holding(node) : node.url ?? "")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .boost(let id):
            StoreHead(id: id, item: item, meter: browser.hoard.meter)
        case .storeMake(let kind):
            StoreMakeHead(kind: kind, item: item, meter: browser.hoard.meter, name: browser.chatName)
        case .chat(let id):
            if let chat = Chats.shared.chat(id) { chatHead(chat, item: item) }
        case .project(let id):
            if let project = Projects.shared.project(id) {
                HStack(spacing: 12) {
                    ProjectCircle(project: project, size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(2)
                        Text(item.source)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                }
            }
        case .routine(let id):
            if let routine = Routines.shared.all.first(where: { $0.id == id }) { routineHead(routine, item: item) }
        case .snippet(let id):
            if let snippet = MailSnippets.shared.snippet(id) { snippetHead(snippet, item: item) }
        case .thread(let thread):
            ThreadPreviewHead(thread: thread, on: browser.prefs.diaryText)
        case .visit(let url, let title, let key, _, _):
            VisitPicture(key: key, url: url, on: browser.prefs.diaryText)
            HStack(spacing: 12) {
                PlaceTileView(tile: item.tile, meter: browser.hoard.meter)
                    .scaleEffect(1.6)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                    Text(url.absoluteString)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .hint, .purchase:
            HStack(spacing: 12) {
                PlaceTileView(tile: item.tile, meter: browser.hoard.meter)
                    .scaleEffect(1.6)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(3)
                    if !item.source.isEmpty {
                        Text(item.source)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    /// A snippet: its words alone, as they go in.
    private func snippetHead(_ snippet: MailSnippet, item: PlaceItem) -> some View {
        Text(snippet.body)
            .font(.system(size: 13.5))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A routine: its name and when, what it is told to do, and what its
    /// last run answered, as its chat has it.
    @ViewBuilder
    private func routineHead(_ routine: Routine, item: PlaceItem) -> some View {
        HStack(spacing: 12) {
            PlaceTileView(tile: item.tile, meter: browser.hoard.meter)
                .scaleEffect(1.6)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(routine.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Text(Routines.say(routine.when))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
        }
        if !routine.prompt.isEmpty {
            Text(routine.prompt)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Omnibox.tileFill))
        }
        if let answer = routine.chat.flatMap({ Chats.shared.chat($0) })?.answer, !answer.isEmpty {
            Text(AgentAnswer.rich(answer))
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineLimit(12)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
        }
    }

    /// A chat: its title and agent, what was first asked, and the answer
    /// as the column writes it.
    @ViewBuilder
    private func chatHead(_ chat: Chat, item: PlaceItem) -> some View {
        HStack(spacing: 12) {
            PlaceTileView(tile: item.tile, meter: browser.hoard.meter)
                .scaleEffect(1.6)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Text(item.tag ?? AgentSetupModel.name(chat.cli))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
        }
        if let asked = chat.items.first(where: { $0.kind == .asked })?.text, !asked.isEmpty {
            Text(asked)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Omnibox.tileFill))
        }
        if !chat.answer.isEmpty {
            Text(AgentAnswer.rich(chat.answer))
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineLimit(12)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
        }
    }

    /// What needs a look, in a line on the warning's wash.
    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Color(nsColor: .systemOrange).opacity(0.1)))
    }

    /// Cards and addresses waiting in the other browsers: what each holds,
    /// and one button that brings it all. Each way in on its own is ⌘K's.
    private var bringHead: some View {
        let wallets = query.stock.wallets ?? []
        let cards = wallets.reduce(0) { $0 + $1.cards }
        return VStack(spacing: 0) {
            FeatureTile(icon: FieldPlace.autofill.symbol, tint: FieldPlace.autofill.tint, side: 56)
            Text(cards > 0 ? "Your cards are in other browsers" : "Your addresses are in other browsers")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.ink)
                .padding(.top, 16)
            Text(wallets.count == 1 ? "macOS asks once for \(wallets[0].source.name)’s key. Nothing changes in \(wallets[0].source.name)."
                                    : "macOS asks once for each browser’s key. Nothing changes in them.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(wallets, id: \.source.id) { wallet in
                    HStack(spacing: 8) {
                        if let icon = wallet.source.icon {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        }
                        Text(wallet.source.name).foregroundStyle(Palette.ink)
                        Text(Browser.walletCount(wallet.cards, wallet.addresses)).foregroundStyle(Palette.muted)
                    }
                    .font(.system(size: 13))
                }
            }
            .padding(.top, 20)
            if let first = browser.bringActions().first {
                Button(action: first.run) {
                    HStack(spacing: 6) {
                        Text(first.title)
                        KeyGlyphs(keys: "↩", size: 12.5, tint: nil, rest: 0.6)
                            .transaction { $0.animation = nil }
                    }
                }
                .buttonStyle(.yab(.primary, .regular))
                .padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    /// You: your name and what you do, or, knowing nothing yet, the ways
    /// yab gets to know you.
    @ViewBuilder
    private var profileHead: some View {
        let profile = query.stock.profile
        if profile.isEmpty, browser.knowingSession == nil {
            VStack(spacing: 0) {
                FeatureTile(icon: "person.text.rectangle", tint: FieldPlace.autofill.tint, side: 56)
                Text("Yab doesn’t know you yet")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .padding(.top, 16)
                Text("Your name, work and links, so any form fills as you. Yab reads your own pages and keeps where each line came from.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
                    .padding(.top, 6)
                let actions = browser.profileActions().filter { ["know", "mecard", "edit"].contains($0.id) }
                    .sorted { ["know", "edit", "mecard"].firstIndex(of: $0.id)! < ["know", "edit", "mecard"].firstIndex(of: $1.id)! }
                if let first = actions.first {
                    Button(action: first.run) {
                        HStack(spacing: 6) {
                            Text(first.title)
                            KeyGlyphs(keys: "↩", size: 12.5, tint: nil, rest: 0.6)
                                .transaction { $0.animation = nil }
                        }
                    }
                    .buttonStyle(.yab(.primary, .regular))
                    .padding(.top, 20)
                }
                ForEach(actions.dropFirst(), id: \.id) { action in
                    Button(action.title, action: action.run)
                        .buttonStyle(.yab(.quiet, .small))
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
        } else {
            HStack(spacing: 12) {
                PlaceTileView(tile: .symbol("person.text.rectangle"), meter: browser.hoard.meter)
                    .scaleEffect(1.6)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name.isEmpty ? "You" : profile.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text([profile.headline.isEmpty ? nil : profile.headline, profile.updated.map { "Updated " + PlacePreview.when($0).lowercased() }]
                        .compactMap { $0 }.first ?? "")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
            }
        }
    }

    private func facts(_ item: PlaceItem) -> [Fact] {
        switch item.what {
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { return [Fact("Status", "Moved or deleted")] }
            return [Fact("Size", ByteCountFormatter.string(fromByteCount: PlacePreview.size(url.path), countStyle: .file)),
                    Fact("Where", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath, copy: .text(url.path))]
        case .kept(let keep):
            var out: [Fact] = []
            if let page = keep.page {
                out.append(Fact("From", keep.pageTitle ?? page.host() ?? page.absoluteString, copy: .text(page.absoluteString), link: true))
                out.append(Fact("Site", Browser.siteName(page.host() ?? keep.from)))
            } else if !keep.from.isEmpty {
                out.append(Fact("From", keep.from))
            }
            if keep.stillThere {
                out.append(Fact("Size", ByteCountFormatter.string(fromByteCount: PlacePreview.size(keep.path), countStyle: .file)))
                out.append(Fact("Where", (keep.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath, copy: .text(keep.path)))
            }
            out.append(Fact("Downloaded", PlacePreview.when(keep.date)))
            return out
        case .shelf(let one):
            var out: [Fact] = []
            switch one.origin {
            case .mail(_, _, _, let from, let to, let subject, let sent):
                if sent {
                    out.append(Fact("To", to.map(ShelfFile.person).joined(separator: ", ")))
                } else {
                    out.append(Fact("From", ShelfFile.person(from), copy: .text(from.address)))
                }
                if !subject.isEmpty { out.append(Fact("Mail", subject, copy: .run("page"), link: true)) }
                out.append(Fact(sent ? "Sent" : "Received", PlacePreview.when(one.date)))
            case .upload(let host):
                out.append(Fact("Sent to", Browser.siteName(host)))
                out.append(Fact("Sent", PlacePreview.when(one.date)))
            }
            out.append(Fact("Size", ByteCountFormatter.string(fromByteCount: Int64(one.size), countStyle: .file)))
            if let path = one.path {
                out.append(Fact("Where", (URL(fileURLWithPath: path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath, copy: .text(path)))
            }
            return out
        case .fetch(let fetch):
            // How far it has got is said under its name, as it comes.
            return [Fact("From", fetch.from), Fact("Started", PlacePreview.when(fetch.started))]
        case .login(let entry):
            let shown = query.revealed?.id == "login." + entry.id ? query.revealed?.text : nil
            var out = [
                Fact("User name", entry.user, copy: .text(entry.user, passing: true)),
                Fact("Password", shown ?? "••••••••••••", copy: .password(entry.host, entry.user), style: shown == nil ? .dots : .mono),
            ]
            if case .code(let host, let user)? = query.edit?.kind, host == entry.host, user == entry.user {
                // Being added: the field stands where its line will be.
                var fact = Fact("One-time code", "")
                fact.editing = true
                out.append(fact)
            } else if query.stock.codes.contains(entry.id) {
                // Shown as it is while Touch ID holds, turning over by itself.
                let proven = query.shown["code." + entry.id] != nil || Browser.placeProven.map { Date().timeIntervalSince($0) < Vault.grace } ?? false
                out.append(Fact("One-time code", "••• •••", copy: .code(entry.host, entry.user), style: proven ? .live(entry.host, entry.user) : .dots))
            } else {
                out.append(Fact("One-time code", "Add a Code…", copy: .run("addcode"), link: true))
            }
            if let used = entry.used { out.append(Fact("Last used", PlacePreview.when(used))) }
            if let saved = entry.saved { out.append(Fact("Saved", PlacePreview.when(saved))) }
            return out
        case .card:
            return []
        case .address(let address):
            let city = [address.city, [address.region, address.postal].filter { !$0.isEmpty }.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: ", ")
            let lines: [(String, String)] = [("Name", address.name), ("Company", address.organization), ("Street", address.street.replacingOccurrences(of: "\n", with: ", ")),
                                             ("City", city), ("Country", address.country), ("Phone", address.phone), ("Email", address.email)]
            var out = lines.filter { !$0.1.isEmpty }.map { Fact($0.0, $0.1, copy: .text($0.1, passing: true)) }
            if let used = address.used { out.append(Fact("Last used", PlacePreview.when(used) + ((address.usedOn ?? "").isEmpty ? "" : " on \(address.usedOn ?? "")"))) }
            if let source = address.source, !source.isEmpty { out.append(Fact("From", source)) }
            if let saved = address.saved { out.append(Fact("Saved", PlacePreview.when(saved))) }
            return out
        case .profile:
            let profile = query.stock.profile
            guard !profile.isEmpty || browser.knowingSession != nil else { return [] }
            var out = Browser.profileLines.filter { !profile[$0.key].isEmpty }.map { line in
                var fact = Fact(line.label, profile[line.key], copy: .text(profile[line.key], passing: true))
                fact.note = Browser.profileSource(profile.sources[line.key] ?? "")
                fact.mine = profile.edited.contains(line.key)
                return fact
            }
            let missing = Browser.profileLines.filter { profile[$0.key].isEmpty }.map(\.label)
            if !missing.isEmpty { out.append(Fact("Not known", missing.joined(separator: ", "), copy: .run("edit"), style: .faint)) }
            if query.stock.answered > 0 {
                out.append(Fact("Saved answers", "\(query.stock.answered) question\(query.stock.answered == 1 ? "" : "s")"))
            }
            return out
        case .draft, .bring:
            return []
        case .bookmark(let node):
            let folder = browser.bookmarks.trail(to: node.id)?.dropLast().last?.id
            var out: [Fact] = []
            if let link = node.url {
                out.append(Fact("Address", link, copy: .text(link), link: true))
            } else {
                // What is in it, the first few, the rest a Return away.
                let kids = node.children ?? []
                for kid in kids.prefix(6) {
                    out.append(Fact(kid.isFolder ? "Folder" : kid.host.map(Browser.site) ?? "Site", kid.title, copy: kid.url.map { .text($0) }))
                }
                if kids.count > 6 { out.append(Fact("And", "\(kids.count - 6) more", copy: .run("open"), link: true)) }
            }
            out.append(Fact("In", browser.bookmarks.path(of: folder)))
            if let added = node.added { out.append(Fact("Added", PlacePreview.when(added))) }
            return out
        case .boost(let id):
            return StoreHead.facts(id)
        case .storeMake:
            return []
        case .purchase(let id):
            guard let item = Purchases.shared.item(id) else { return [] }
            return PlacePreview.purchaseFacts(item)
        case .hint(let id):
            guard let hint = Hints.shared.row(id) else { return [] }
            let kind = Noticing.Kind.of(hint)
            var out = [Fact("Kind", kind?.title ?? "Found by an agent")]
            if let sender = hint.sender { out.append(Fact("From", sender.name.isEmpty ? sender.address : sender.name, copy: .text(sender.address))) }
            if let due = hint.due { out.append(Fact(kind == .meeting ? "Starts" : "When", PlacePreview.when(due))) }
            if let copied = hint.copied { out.append(Fact("Copied", PlacePreview.when(copied))) }
            if let phone = hint.phone { out.append(Fact("On iPhone", PlacePreview.when(phone))) }
            if let url = hint.join ?? hint.url {
                out.append(Fact("Page", url.host().map(Browser.siteName) ?? url.absoluteString, copy: .text(url.absoluteString), link: true))
            }
            if hint.draft != nil { out.append(Fact("Reply", "Written, put in as it opens")) }
            if let seen = hint.seen { out.append(Fact("Opened", PlacePreview.when(seen))) }
            return out
        case .project(let id):
            guard let project = Projects.shared.project(id) else { return [] }
            var out = [Fact("Chats", "\(Chats.shared.of(project: id).count)")]
            let said = project.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty { out.append(Fact("Instructions", String(said.prefix(140)))) }
            out.append(Fact("Memory", project.memoryOn ? "On" : "Off"))
            out.append(Fact("Made", PlacePreview.when(project.created)))
            return out
        case .chat(let id):
            guard let chat = Chats.shared.chat(id) else { return [] }
            var out = [Fact("Model", AgentModels.find(chat.cli, chat.model)?.name ?? AgentSetupModel.name(chat.cli))]
            if !chat.tabs.isEmpty { out.append(Fact("Tabs opened", "\(chat.tabs.count)")) }
            out.append(Fact("Started", PlacePreview.when(chat.started)))
            out.append(Fact("Last active", PlacePreview.when(chat.updated)))
            if chat.archived == true {
                out.append(Fact("Archived", "Yes"))
            } else if !chat.pinned, let wait = Chat.archiveAfter.seconds {
                out.append(Fact("Archived on", chat.updated.addingTimeInterval(wait).englishFormatted(date: .abbreviated, time: .omitted)))
            }
            return out
        case .routine(let id):
            guard let routine = Routines.shared.all.first(where: { $0.id == id }) else { return [] }
            var out = [Fact("Runs", Routines.say(routine.when))]
            if let ended = routine.ended { out.append(Fact("Last run", PlacePreview.when(ended))) }
            if routine.off != true, let next = Routines.next(routine, after: Date()) { out.append(Fact("Next run", PlacePreview.when(next))) }
            let hosts = Routines.hosts(routine)
            if !hosts.isEmpty { out.append(Fact("Works in", hosts.joined(separator: ", "))) }
            let model = routine.cli.map { AgentModels.find($0, routine.model)?.name ?? AgentModels.agentName($0) } ?? "Default"
            out.append(Fact("Model", model))
            return out
        case .snippet(let id):
            guard let snippet = MailSnippets.shared.snippet(id) else { return [] }
            var out = [Fact("Name", snippet.name), Fact("Type", ";" + snippet.name, copy: .text(";" + snippet.name))]
            if let key = Hotkey(stored: snippet.hotkey) { out.append(Fact("Shortcut", key.caps.joined())) }
            out.append(Fact("Works", snippet.whereSaid))
            if snippet.mailOnly {
                if !snippet.subject.isEmpty { out.append(Fact("Subject", snippet.subject)) }
                if !snippet.to.isEmpty { out.append(Fact("To", snippet.to)) }
                if !snippet.files.isEmpty { out.append(Fact("Files", snippet.files.map(\.name).joined(separator: ", "))) }
            }
            out.append(Fact("Times used", "\(snippet.uses)"))
            if let used = snippet.used { out.append(Fact("Last used", PlacePreview.when(used))) }
            out.append(Fact("Created", PlacePreview.when(snippet.made)))
            return out
        case .visit(let url, _, _, let at, let count):
            return [Fact("Address", url.absoluteString, copy: .text(url.absoluteString), link: true),
                    Fact("Visited", PlacePreview.when(at)), Fact("Visits that day", "\(count)")]
        case .thread(let thread):
            return thread.did.map { Fact($0.time, $0.words) }
        }
    }

    static let top = "preview.top"

    /// A file's size, read once a path: the preview is drawn on every step.
    @MainActor static var sizes: [String: Int64] = [:]
    /// A purchase's lines: what it costs and how, when it comes again or
    /// arrives, whether its site is used, and its mail.
    @MainActor static func purchaseFacts(_ item: Purchases.Item) -> [Fact] {
        let p = item.purchase
        var out: [Fact] = []
        let day = { (date: Date) in date.englishFormatted(date: .abbreviated, time: .omitted) }
        switch p.kind {
        case .order:
            if let status = Purchases.status(p) { out.append(Fact("Status", status)) }
            if let arrives = p.arrives { out.append(Fact("Arrives", day(arrives))) }
            if let tracking = p.tracking { out.append(Fact(p.carrier ?? "Tracking", tracking, copy: .text(tracking), style: .mono)) }
            if let order = p.order { out.append(Fact("Order", order, copy: .text(order))) }
            if let price = item.price { out.append(Fact("Paid", price)) }
        case .subscription:
            if let price = item.price { out.append(Fact("Price", price)) }
            if p.canceled {
                out.append(Fact("Canceled", p.ends.map { "Yours until " + day($0) } ?? "Yes"))
            } else if let renews = p.renews {
                out.append(Fact("Next charge", day(renews)))
            }
            if let card = item.card { out.append(Fact("Card", card)) }
            if let idle = item.idle(now: Date()) {
                out.append(Fact("Last opened", idle >= Purchases.window ? "Not this year" : idle == 0 ? "Today" : "\(idle) days ago"))
            }
        case .receipt:
            if let price = item.price { out.append(Fact("Paid", price)) }
            if let card = item.card { out.append(Fact("Card", card)) }
            if let order = p.order { out.append(Fact("Order", order, copy: .text(order))) }
        }
        out.append(Fact(p.kind == .order ? "Mail" : "Receipt", p.date.englishFormatted(date: .abbreviated, time: .omitted), copy: .run("page"), link: true))
        if let host = p.host { out.append(Fact("Site", Browser.siteName(host), copy: .text("https://" + host), link: true)) }
        return out
    }

    @MainActor static func size(_ path: String) -> Int64 {
        if let hit = sizes[path] { return hit }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        if sizes.count > 500 { sizes.removeAll() }
        sizes[path] = size
        return size
    }

    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.englishFormatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today at \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return date.englishFormatted(date: .abbreviated, time: .shortened)
    }
}

/// One line of a place's Information: what it is, and its value, which,
/// where it can be, is copied by a click.
struct Fact {
    enum Copy {
        /// Words; `passing` ones are marked so the clipboard's history
        /// doesn't keep them.
        case text(String, passing: Bool = false)
        case password(String, String)
        case code(String, String)
        case card(String, String)
        /// A card's security code: its id and its name.
        case cardCode(String, String)
        /// Not a copy: the action of that id, as ⌘K has it (Add a Code…).
        case run(String)
    }
    enum Style: Equatable {
        case plain, mono, dots, faint
        /// A one-time code, as it is now.
        case live(String, String)
    }

    let label: String
    let value: String
    var copy: Copy?
    var link = false
    var style = Style.plain
    /// Beside the value, small: where it came from ("LinkedIn").
    var note = ""
    /// Written by you: the note in the accent.
    var mine = false
    /// Being written where it stands (CodeEditLine).
    var editing = false

    var run: Bool {
        if case .run = copy { return true }
        return false
    }

    init(_ label: String, _ value: String, copy: Copy? = nil, link: Bool = false, style: Style = .plain) {
        self.label = label
        self.value = value
        self.copy = copy
        self.link = link
        self.style = style
    }

    /// Where a secret stays shown once Touch ID let it be copied
    /// (Query.shown); nil for what isn't one.
    var shownKey: String? {
        switch copy {
        case .password(let host, let user): return "password." + host + "\u{1}" + user
        case .code(let host, let user): return "code." + host + "\u{1}" + user
        case .card(let id, _): return "number." + id
        case .cardCode(let id, _): return "csc." + id
        default: return nil
        }
    }

    /// Whether copying it waits for Touch ID.
    var secret: Bool { shownKey != nil }
}

/// A line of Information: its label, and its value (CopyValue).
struct FactLine: View {
    let fact: Fact
    let browser: Browser
    var height: CGFloat = 34

    var body: some View {
        HStack(spacing: 12) {
            Text(fact.label)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            CopyValue(fact: fact, browser: browser, query: browser.query, alignment: .trailing)
            if !fact.note.isEmpty {
                Text(fact.note)
                    .font(.system(size: 11))
                    .foregroundStyle(fact.mine ? Color.accentColor : Palette.faint)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: height)
    }
}

/// A value that copies itself, as the passwords page's do. No plate until
/// the pointer is on it, and the plate is never narrower than what it will
/// say: "Copied", or for a secret "Waiting for Touch ID…", so a click
/// never widens it. A click dips it into a blur; a secret shimmers
/// "Waiting for Touch ID…" until the Mac's owner answers; then it comes
/// out as a gray "Copied" beside two pages and, two seconds later, goes
/// back the same way, a secret now shown in the clear so it can be read out, until
/// another row is chosen. The box stays: one value, then another.
struct CopyValue: View {
    let fact: Fact
    let browser: Browser
    @ObservedObject var query: Query
    var alignment: Alignment = .trailing
    var size: CGFloat = 13
    @State private var hovering = false
    @State private var copied = false
    @State private var waiting = false
    @State private var dipped = false
    @State private var back: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) private var still

    static let wait = "Waiting for Touch ID…"

    var body: some View {
        if fact.copy != nil {
            Button(action: take) { face }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .keyTip(fact.run ? fact.value : "Copy")
        } else {
            face
        }
    }

    private var shown: String? { fact.shownKey.flatMap { query.shown[$0] } }

    private var face: some View {
        ZStack(alignment: copied || waiting ? .center : alignment) {
            // What it will say, unseen, holding the plate at its width.
            copiedLabel.hidden()
            if fact.secret { Text(Self.wait).font(.system(size: size - 0.5)).hidden() }
            if copied {
                copiedLabel
            } else if waiting {
                Shimmer(text: Self.wait, size: size - 0.5)
            } else if case .live(let host, let user) = fact.style {
                LiveCode(host: host, user: user)
            } else {
                let dots = shown == nil && fact.style == .dots
                Text(shown ?? fact.value)
                    .font(shown != nil || (fact.style != .plain && fact.style != .faint) ? .system(size: size - 0.5, design: .monospaced) : .system(size: size))
                    .kerning(dots ? 2 : 0)
                    .foregroundStyle(fact.link ? Color.accentColor : dots ? Palette.muted : fact.style == .faint ? Palette.faint : Palette.ink)
                    .lineLimit(1)
                    .truncationMode(fact.style == .faint ? .tail : .middle)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
            .fill(Omnibox.chosenFill.opacity(copied || waiting || (hovering && fact.copy != nil) ? 1 : 0)))
        .padding(.horizontal, -8)
        .blur(radius: dipped ? 2.5 : 0)
        .scaleEffect(dipped ? 0.96 : 1)
        .opacity(dipped ? 0.45 : 1)
    }

    private var copiedLabel: some View {
        HStack(spacing: 4) {
            Symbol("doc.on.doc.fill", size: size - 1.5)
            Text("Copied")
        }
        .font(.system(size: size - 0.5))
        .foregroundStyle(Palette.muted)
    }

    private func take() {
        guard let copy = fact.copy, !waiting else { return }
        switch copy {
        case .text(let text, let passing):
            browser.put(text, passing: passing)
            done()
        case .password(let host, let user):
            secret("copy the password for \(host)", read: { Vault.password(host: host, user: user) }) { $0 }
        case .code(let host, let user):
            secret("copy the code for \(host)", read: { OneTime.setup(host: host, user: user).map { OneTime.code($0).code } }) { $0 }
        case .run(let id):
            _ = browser.runAction(id)
        case .card(let id, let title):
            secret("copy the number of \(title)", read: { Wallet.number(of: id) }) { Browser.grouped($0) }
        case .cardCode(let id, let title):
            secret("copy the security code of \(title)", read: { Wallet.securityCode(of: id) }) { $0 }
        }
    }

    /// A secret: straight away when it is shown already, Touch ID asked
    /// for this one; else Touch ID first, with the value shimmering while
    /// the Mac asks, and then it stays shown.
    private func secret(_ reason: String, read: @escaping () -> String?, show: @escaping (String) -> String) {
        if shown != nil, let value = read() {
            browser.putSecret(value)
            done()
            return
        }
        dip { waiting = true }
        Wallet.prove(reason) { proven in
            guard proven == .yes, let value = read() else {
                dip { waiting = false }
                return
            }
            browser.putSecret(value)
            if let key = fact.shownKey { query.shown[key] = show(value) }
            waiting = false
            done(dipIn: false)
        }
    }

    private func done(dipIn: Bool = true) {
        if dipIn { dip { copied = true } } else { copied = true }
        back?.cancel()
        let work = DispatchWorkItem { dip { copied = false } }
        back = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    /// Into a blur, the change at its deepest, and out: 0.18 s in, 0.27 out.
    private func dip(_ change: @escaping () -> Void) {
        guard !still else { change(); return }
        withAnimation(.easeIn(duration: 0.18)) { dipped = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            change()
            withAnimation(.easeOut(duration: 0.27)) { dipped = false }
        }
    }
}

/// Words with a light passing across them, as the passwords page's
/// "Waiting for Touch ID…" has: only while something is waited for.
struct Shimmer: View {
    let text: String
    var size: CGFloat = 12.5
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        if still {
            Text(text).font(.system(size: size)).foregroundStyle(Palette.muted)
        } else {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                let at = -0.3 + 1.6 * phase
                Text(text)
                    .font(.system(size: size))
                    .foregroundStyle(LinearGradient(stops: [
                        .init(color: Palette.muted, location: 0),
                        .init(color: Palette.muted, location: max(0, min(1, at - 0.15))),
                        .init(color: Palette.ink, location: max(0, min(1, at))),
                        .init(color: Palette.muted, location: max(0, min(1, at + 0.15))),
                        .init(color: Palette.muted, location: 1),
                    ], startPoint: .leading, endPoint: .trailing))
            }
        }
    }
}

/// A card in its place: its network and name, then what a checkout form
/// asks for, each in a box of its own as the form has it, each copied by a
/// click; and under them the address it is billed to, line by line, with
/// a button for all of it.
struct CardDetail: View {
    let browser: Browser
    @ObservedObject var query: Query
    let card: SavedCard
    let faded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PayMark(kind: card.brand, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.shortTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    if let used = card.used {
                        Text("Last used " + PlacePreview.when(used).lowercased() + (card.usedOn.isEmpty ? "" : " on \(card.usedOn)"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.muted)
                    }
                }
            }
            .opacity(faded ? 0.55 : 1)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    CardBox(label: "Card number", fact: Fact("", "•••• •••• •••• \(card.last4)", copy: .card(card.id, card.title), style: .dots), browser: browser)
                        .gridCellColumns(2)
                }
                GridRow {
                    CardBox(label: "Expiry", fact: Fact("", card.expiry, copy: .text(card.expiry, passing: true)), browser: browser)
                    if card.keepsCode {
                        CardBox(label: "Security code", fact: Fact("", "•••", copy: .cardCode(card.id, card.title), style: .dots), browser: browser)
                    } else {
                        CardBox(label: "Security code", fact: Fact("", "Not kept"), browser: browser, quiet: true)
                    }
                }
                GridRow {
                    CardBox(label: "Name on card", fact: card.name.isEmpty ? Fact("", "None") : Fact("", card.name, copy: .text(card.name, passing: true)),
                              browser: browser, quiet: card.name.isEmpty)
                        .gridCellColumns(2)
                }
            }
            if let billing = Wallet.billing(of: card, among: query.stock.addresses) {
                HStack {
                    Text("Billing address")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                    CopyButton(title: "Copy Address") { browser.put(Browser.lines(of: billing), passing: true) }
                }
                .padding(.horizontal, 8)
                let lines: [(String, String)] = [("Name", billing.name), ("Street", billing.street.replacingOccurrences(of: "\n", with: ", ")),
                                                 ("City", billing.city), ("State", billing.region), ("ZIP", billing.postal), ("Country", billing.country)]
                let shown = lines.filter { !$0.1.isEmpty }
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                        FactLine(fact: Fact(line.0, line.1, copy: .text(line.1, passing: true)), browser: browser, height: 30)
                        if index < shown.count - 1 {
                            Rectangle().fill(Omnibox.seam).frame(height: 0.5).padding(.horizontal, 8)
                        }
                    }
                }
            }
        }
    }
}

/// One of a card's values in a box of its own, as a checkout form has it:
/// what it is, small, over the value that copies itself.
struct CardBox: View {
    let label: String
    let fact: Fact
    let browser: Browser
    var quiet = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
            if quiet {
                Text(fact.value)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            } else {
                CopyValue(fact: fact, browser: browser, query: browser.query, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Palette.ground.opacity(0.6))) // design: a form's field, not a card
        .overlay(shape.strokeBorder(Omnibox.seam, lineWidth: 0.5)) // design: a form's field, not a card
    }
}

/// A small button that copies, and says so in its own place: its words dip
/// into a blur and come out as "Copied", then back, never wider than it is.
struct CopyButton: View {
    let title: String
    let copy: () -> Void
    @State private var copied = false
    @State private var dipped = false
    @State private var back: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        Button {
            copy()
            dip { copied = true }
            back?.cancel()
            let work = DispatchWorkItem { dip { copied = false } }
            back = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
        } label: {
            ZStack {
                Text(title).hidden()
                if copied {
                    HStack(spacing: 4) {
                        Symbol("checkmark", size: 9)
                        Text("Copied")
                    }
                    .foregroundStyle(Color(nsColor: .systemGreen))
                } else {
                    Text(title)
                }
            }
            .blur(radius: dipped ? 2.5 : 0)
            .opacity(dipped ? 0.45 : 1)
        }
        .buttonStyle(.yab(.secondary, .small))
    }

    private func dip(_ change: @escaping () -> Void) {
        guard !still else { change(); return }
        withAnimation(.easeIn(duration: 0.18)) { dipped = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            change()
            withAnimation(.easeOut(duration: 0.27)) { dipped = false }
        }
    }
}

/// "Into Password · github.com" at the field's end: where ↩ puts the
/// chosen row. Or, in the warning's color, why it won't go in.
struct PlaceTargetView: View {
    let target: PlaceTarget

    var body: some View {
        HStack(spacing: 4) {
            if target.refused {
                Text(target.what)
                    .foregroundStyle(Color(nsColor: .systemOrange))
            } else {
                Text("Into")
                    .foregroundStyle(Palette.muted)
                    .fixedSize()
                // A page's own words for its box can run to a sentence
                // (a drop zone's "Drag and drop… or click to upload"): they
                // give way, never the card's width.
                Text(target.what)
                    .foregroundStyle(Color.accentColor)
                    .truncationMode(.tail)
                if !target.host.isEmpty {
                    Text("· \(target.host)")
                        .foregroundStyle(Palette.muted)
                        .fixedSize()
                }
            }
        }
        .font(.system(size: 13.5))
        .lineLimit(1)
        .keyTip(target.refused ? "Only copied: a password goes into its own site’s page" : "Return puts it here")
    }
}

/// Quick Look's pictures of files: the first page of a PDF, a picture
/// itself, a frame of a video, a document's page. Made in the background,
/// once a file and size, and kept; until one comes the file's icon stands.
/// Each view waits for its own (`picture(_:side:)`): one arriving redraws
/// that row, not every row that shows a file.
@MainActor
final class Thumbs {
    static let shared = Thumbs()
    private var made: [String: NSImage] = [:]
    private var icons: [String: NSImage] = [:]
    private var waiting: [String: [CheckedContinuation<NSImage?, Never>]] = [:]

    /// What is made already, without waiting.
    func cached(_ path: String, side: CGFloat) -> NSImage? { made["\(Int(side))|\(path)"] }

    /// A type icon is enough until Quick Look responds. Reading every file's
    /// individual icon while eight rows appear would add synchronous disk
    /// work to the opening frame.
    func icon(for path: String) -> NSImage {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if let icon = icons[ext] { return icon }
        let icon = NSWorkspace.shared.icon(forFileType: ext.isEmpty ? "public.data" : ext)
        icons[ext] = icon
        return icon
    }

    func picture(_ path: String, side: CGFloat) async -> NSImage? {
        let key = "\(Int(side))|\(path)"
        if let hit = made[key] { return hit }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return await withCheckedContinuation { continuation in
            let first = waiting[key] == nil
            waiting[key, default: []].append(continuation)
            guard first else { return }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: side * 1.6, height: side),
                                                       scale: scale, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumb, _ in
                let image = thumb?.nsImage
                DispatchQueue.main.async {
                    if self.made.count > 300 { self.made.removeAll() }
                    if let image { self.made[key] = image }
                    self.waiting.removeValue(forKey: key)?.forEach { $0.resume(returning: image) }
                }
            }
        }
    }
}

/// A file's picture at a side, or its icon until the picture comes.
struct FilePicture: View {
    let path: String
    let side: CGFloat
    var fill = false
    @State private var picture: (path: String, image: NSImage)?

    var body: some View {
        Group {
            if let image = (picture?.path == path ? picture?.image : nil) ?? Thumbs.shared.cached(path, side: side) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Image(nsImage: Thumbs.shared.icon(for: path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: side < 40 ? side : 64, maxHeight: side < 40 ? side : 64)
            }
        }
        .task(id: path) {
            if let image = await Thumbs.shared.picture(path, side: side), !Task.isCancelled {
                picture = (path, image)
            }
        }
    }
}

/// A file's row mark: Quick Look's picture of it on a tile, or its icon.
struct PlaceFileTile: View {
    let path: String

    var body: some View {
        FilePicture(path: path, side: Omnibox.tile, fill: true)
            .frame(width: Omnibox.tile, height: Omnibox.tile)
            .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}

/// An empty place, in its middle, as Settings' "Add your first extension"
/// is: the place's tile, a heading and a line, the ways to fill it in a row
/// to choose among, and one button, what ↩ does, for the one chosen. A
/// search that found nothing is quieter: a gray magnifier, no tile, and
/// its one way on in a plain button.
struct PlaceEmptyView: View {
    let browser: Browser
    @ObservedObject var query: Query
    let empty: PlaceEmpty

    var body: some View {
        VStack(spacing: 0) {
            if empty.searching {
                Symbol("magnifyingglass", size: 22)
                    .foregroundStyle(Palette.faint)
            } else {
                // The place's tile large, as a Settings page's hero wears its own.
                FeatureTile(icon: empty.place.symbol, tint: empty.place.tint, side: 56)
            }
            Text(empty.title)
                .font(.system(size: empty.searching ? 15 : 17, weight: .medium))
                .foregroundStyle(empty.searching ? Palette.muted : Palette.ink)
                .lineLimit(2)
                .padding(.top, empty.searching ? 12 : 16)
            if !empty.detail.isEmpty {
                Text(empty.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
                    .padding(.top, 6)
            }
            if empty.busy {
                ProgressView().controlSize(.small)
                    .padding(.top, 20)
            }
            if !empty.sources.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(empty.sources.enumerated()), id: \.offset) { index, source in
                        Button { query.spot = index } label: {
                            HStack(spacing: 6) {
                                if let icon = source.icon {
                                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                                } else if let symbol = source.symbol {
                                    Symbol(symbol, size: 10)
                                }
                                Text(source.name)
                                if !source.detail.isEmpty {
                                    Text(source.detail).foregroundStyle(Palette.muted)
                                }
                            }
                        }
                        .buttonStyle(.yab(index == min(query.spot, empty.sources.count - 1) ? .secondary : .quiet, .small))
                    }
                }
                .padding(.top, 16)
            }
            if let first = empty.actions.first {
                Button(action: first.run) {
                    HStack(spacing: 6) {
                        Text(first.title)
                        KeyGlyphs(keys: "↩", size: 12.5, tint: nil, rest: 0.6)
                            .transaction { $0.animation = nil }
                    }
                }
                .buttonStyle(.yab(empty.searching ? .secondary : .primary, .regular))
                .padding(.top, empty.searching ? 16 : 20)
            }
            if let note = empty.footnote {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
                    .padding(.top, 12)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .padding(.bottom, FieldFoot.room)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What a page History lists looked like: yab's own picture from when you
/// were on it, or else the one it offers for sharing, asked for once when
/// there is neither (Diary.look). Nothing while pages' words aren't kept.
struct VisitPicture: View {
    let key: String
    let url: URL
    let on: Bool
    @State private var picture: NSImage?

    var body: some View {
        Group {
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: 150, alignment: .top)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5)) // design: a picture's edge, as the file previews have it, not a card
            }
        }
        .task(id: key) {
            picture = VisitPicture.read(key)
            guard picture == nil, on, ["http", "https"].contains(url.scheme ?? "") else { return }
            let link = await withCheckedContinuation { go in Diary.shared.look(key: key, url: url) { go.resume(returning: $0) } }
            if !link.isEmpty { picture = VisitPicture.read(key) }
        }
    }

    static func read(_ key: String) -> NSImage? {
        for file in [Diary.shot(key), Diary.og(key)] where FileManager.default.fileExists(atPath: file.path) {
            return NSImage(contentsOf: file)
        }
        return nil
    }
}
