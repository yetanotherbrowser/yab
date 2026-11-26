import SwiftUI

// A pin's card lists what is there, in place of the picture of the page:
// a calendar's meetings left today, a site's live folder, or the pages you
// last opened on that site. Resting on the pin brings it, as a shut
// folder's preview comes (Glance.swift), and it is worked the same way:
// letters search it, ↑↓ pick, Return opens, Escape puts it away. Arc's
// previews of a favorite's recent items, for every site at once, from what
// yab already knows, with no integration to keep working
// (docs/live-folders.md).

/// One line of a pin's card.
struct PinItem: Identifiable, Equatable {
    let id: String
    let title: String
    /// At the line's end: when, or what it needs.
    let detail: String
    /// Something to do: drawn in ink.
    var strong = false
    /// The site's mark, for a page.
    var host: String?
    let open: @MainActor () -> Void

    static func == (a: PinItem, b: PinItem) -> Bool {
        a.id == b.id && a.title == b.title && a.detail == b.detail && a.strong == b.strong
    }
}

@MainActor
enum PinList {
    /// Whether this pin's card is a list: every pin with a page has at
    /// least its site's recent pages, once it has any.
    static func wanted(_ tab: Tab) -> Bool {
        guard tab.pin != nil, tab.address?.host() != nil else { return false }
        // A calendar with nothing connected has no meetings to list: its
        // card is the tab's, saying so with Connect (TabGist).
        return !(Meetings.isCalendar(tab.address) && Meetings.shared.unconnected)
    }

    /// What its card says it is: "Today", the folder's name, "Recent here".
    static func heading(_ tab: Tab, in browser: Browser) -> String {
        if browser.pinMate(of: tab) != nil { return "Split View" }
        if Meetings.isCalendar(tab.address) { return "Today" }
        if MailPage.isMail(tab.address) { return "Needs you" }
        if tab.address?.host() == "mail.google.com" { return "Unread" }
        if let nest = liveNest(for: tab, in: browser) { return nest.name }
        return "Recent here"
    }

    /// The lines, for the words typed; a site's history is read off the
    /// main thread, so they come by `done`, perhaps twice.
    static func items(for tab: Tab, in browser: Browser, query: String, done: @escaping @MainActor ([PinItem]) -> Void) {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        func matching(_ items: [PinItem]) -> [PinItem] {
            words.isEmpty ? items : items.filter { $0.title.lowercased().contains(words) }
        }
        // A pinned pair's card: its two halves, each opening the pair with
        // it in front (PinPairs.swift).
        if let mate = browser.pinMate(of: tab), let pair = browser.pinPair(of: tab.id) {
            return done([tab, mate].map { half in
                let host = (half.pending ?? half.address)?.host()
                let site = host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
                return PinItem(id: "half:" + half.id.uuidString, title: half.rowLabel,
                               detail: half.pairRest ? site + " · closed" : site, host: host) { [weak browser] in
                    browser?.openPinPair(pair, front: half.id)
                }
            })
        }
        if Meetings.isCalendar(tab.address) { return done(matching(meetings(in: browser))) }
        if MailPage.isMail(tab.address) { return done(matching(needing(in: browser))) }
        if let nest = liveNest(for: tab, in: browser) { return done(matching(live(nest, in: browser))) }
        if tab.address?.host() == "mail.google.com" { return unread(on: tab, in: browser) { done(matching($0)) } }
        recent(on: tab, in: browser, words: words, done: done)
    }

    /// Gmail's unread, from its feed: who, the subject, when; opened in the
    /// pin.
    static func unread(on tab: Tab, in browser: Browser, done: @escaping @MainActor ([PinItem]) -> Void) {
        let store = Spaces.store(for: browser.spaceID)
        let account = LiveGmail.account(tab.address)
        Task { @MainActor [weak browser, weak tab] in
            guard let read = await LiveGmail.read(account: account, store: store), let browser, let tab else { return done([]) }
            tab.sourced(read.count)
            done(read.entries.map { entry in
                PinItem(id: "mail:" + entry.id, title: entry.author.isEmpty ? entry.title : "\(entry.author): \(entry.title)",
                        detail: entry.at.map(PanelTime.short) ?? "") { [weak browser, weak tab] in
                    guard let browser, let tab else { return }
                    browser.select(tab)
                    tab.go(to: entry.link)
                }
            })
        }
    }

    /// The mail pin's: the threads that want you, the ones its count
    /// counts, newest first: who, the subject, when; opened in mail's space.
    static func needing(in browser: Browser) -> [PinItem] {
        let center = MailCenter.shared
        guard center.connected else { return [] }
        let threads = center.showing("all").flatMap { engine in
            MailSplit.threads(.needs, in: engine.store).map { (engine.account, $0.0) }
        }
        return threads.sorted { $0.1.last > $1.1.last }.map { account, thread in
            let person = thread.people.first
            let who = person.map { $0.said.components(separatedBy: " ").first ?? $0.said } ?? ""
            let subject = thread.subject.isEmpty ? "(no subject)" : thread.subject
            return PinItem(id: "mail:" + account + "|" + thread.id, title: who.isEmpty ? subject : "\(who): \(subject)",
                           detail: PanelTime.short(thread.last),
                           host: person.flatMap { $0.address.split(separator: "@").last.map(String.init) }) { [weak browser] in
                var parts = URLComponents(string: "yab://mail")!
                parts.fragment = "thread=" + account + "|" + thread.id
                browser?.enterMail(parts.url)
            }
        }
    }

    /// The meetings left today, the next one first: "in 12m" within the
    /// hour, Join from a minute before, and the time for the rest.
    static func meetings(in browser: Browser) -> [PinItem] {
        let meetings = Meetings.shared
        let now = Date()
        let calendar = Calendar.current
        let times = AppDates.formatter()
        times.timeStyle = .short
        times.dateStyle = .none
        return meetings.list
            .filter { $0.end > now && calendar.isDate($0.start, inSameDayAs: now) }
            .sorted { $0.start < $1.start }
            .map { meeting in
                let wait = meeting.start.timeIntervalSince(now)
                let joining = wait <= 60 && CallLink.key(meeting.link) != nil
                let detail = joining ? "Join" : wait < 3600 && wait > 0 ? "in \(Int((wait / 60).rounded(.up)))m" : wait <= 0 ? "Now" : times.string(from: meeting.start)
                // Which calendar, when it isn't the account's own: "Launch review (Team)".
                let title = meeting.calendar.map { "\(meeting.title) (\($0))" } ?? meeting.title
                return PinItem(id: "meeting:" + meeting.id, title: title, detail: detail, strong: joining) { [weak browser] in
                    guard let browser else { return }
                    if joining { browser.joinMeeting(meeting) } else if let link = meeting.link { browser.arrive(link) }
                }
            }
    }

    /// A live folder of this pin's site in this window, if there is one.
    static func liveNest(for tab: Tab, in browser: Browser) -> Nest? {
        guard let host = tab.address?.host()?.lowercased() else { return nil }
        return LiveFolders.nests(in: browser).first { nest in
            guard let live = nest.live, let source = LiveSource.of(live.source) else { return false }
            return source.owns(host, live: live)
        }
    }

    /// The folder's tabs, those that need you first.
    static func live(_ nest: Nest, in browser: Browser) -> [PinItem] {
        let tabs = browser.tabs.filter { $0.nest === nest }
        let sorted = tabs.filter { $0.live?.words?.needsYou == true } + tabs.filter { $0.live?.words?.needsYou != true }
        return sorted.map { tab in
            PinItem(id: "tab:" + tab.id.uuidString, title: tab.rowLabel, detail: tab.live?.words?.text ?? "",
                    strong: tab.live?.words?.needsYou == true, host: tab.address?.host()) { [weak browser, weak tab] in
                guard let browser, let tab else { return }
                browser.select(tab)
            }
        }
    }

    /// The pages last opened on the pin's site, newest first; with words,
    /// every page of it they find. Opened in the pin.
    static func recent(on tab: Tab, in browser: Browser, words: String, done: @escaping @MainActor ([PinItem]) -> Void) {
        guard let host = tab.address?.host()?.lowercased() else { return done([]) }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let here = tab.address.map { $0.absoluteString }
        Diary.shared.search("site:\(site) \(words)") { [weak browser, weak tab] result in
            guard let browser, let tab else { return }
            let rows = (result["results"] as? [[String: Any]] ?? []).filter { ($0["url"] as? String) != here }
            let items = rows.prefix(words.isEmpty ? 6 : 12).compactMap { row -> PinItem? in
                guard let link = row["url"] as? String, let url = URL(string: link) else { return nil }
                let at = Date(timeIntervalSince1970: (row["at"] as? Double ?? 0) / 1000)
                let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Address.pretty(url)
                return PinItem(id: "page:" + link, title: Diary.clean(title), detail: PanelTime.short(at), host: row["host"] as? String) { [weak browser, weak tab] in
                    guard let browser, let tab else { return }
                    browser.select(tab)
                    tab.go(to: url)
                }
            }
            MainActor.assumeIsolated { _ = browser; done(items) }
        }
    }
}

/// The card: its heading in the search's place, a seam, the lines; a shut
/// folder's preview (FolderPreview) on Actions' panel, its pieces and all.
struct PinPreview: View {
    let browser: Browser
    @ObservedObject var glance: TabGlance
    let heading: String
    /// A pinned pair's card: its two halves, no search (PinPairs.swift).
    var halves = false
    @Environment(\.colorScheme) private var scheme

    /// Known before presentation, so a bottom-edge card does not first
    /// use the previous preview's measured height and then move upward.
    static func height(_ count: Int) -> CGFloat {
        FolderPreview.field + 1 + 2 * FolderPreview.rowsAir
            + CGFloat(min(max(1, count), TabGlance.previewRows)) * FieldActionsPanel.row
    }

    var body: some View {
        let words = glance.query
        let items = glance.pinItems
        let appearance = LookMode(rawValue: browser.prefs.lookMode)?.scheme ?? scheme
        VStack(alignment: .leading, spacing: 0) {
            if halves {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        PinHalfLine(item: item, lit: index == glance.lit)
                            .contentShape(Rectangle())
                            .onHover { if $0, glance.lit != index { glance.lit = index } }
                            .onTapGesture { glance.pickPin(item) }
                    }
                }
                .padding(.horizontal, FolderPreview.margin)
                .padding(.vertical, FolderPreview.rowsAir)
            } else {
                // The folder preview's search, saying what the card is
                // until words are typed.
                FolderPreviewSearch(glance: glance, placeholder: heading, scheme: appearance)
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                    .padding(.horizontal, FolderPreview.margin + FolderPreview.rowInset)
                    .frame(height: FolderPreview.field)
                FolderPreview.seam
                VStack(spacing: 0) {
                    if items.isEmpty {
                        FolderPreview.empty(words.isEmpty ? "Nothing here yet" : "Nothing matches “\(words.trimmingCharacters(in: .whitespaces))”")
                    } else {
                        ScrollViewReader { scroller in
                            ThreadScrollView {
                                VStack(spacing: 0) {
                                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                        PinLine(item: item, lit: index == glance.lit)
                                            .id(index)
                                            .contentShape(Rectangle())
                                            .onHover { if $0, glance.lit != index { glance.lit = index } }
                                            .onTapGesture { glance.pickPin(item) }
                                    }
                                }
                                .padding(.horizontal, FolderPreview.margin)
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .scrollIndicators(.never)
                            .frame(height: CGFloat(min(items.count, TabGlance.previewRows)) * FieldActionsPanel.row)
                            .onChange(of: glance.lit) { _, row in scroller.scrollTo(row) }
                        }
                    }
                }
                .padding(.vertical, FolderPreview.rowsAir)
            }
        }
        .modifier(PreviewPanel(scheme: appearance))
    }
}

/// A site's mark on a pin's card, from the favicons kept.
@MainActor private func pinMark(_ host: String) -> PreviewMark {
    PreviewMark(icon: Favicons.shared.cached(host), letter: String(host.prefix(1)).uppercased())
}

/// A half of a pinned pair on its card: its mark, its title, its site
/// under it, on a folder preview's row plate.
private struct PinHalfLine: View {
    let item: PinItem
    let lit: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let host = item.host { pinMark(host) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(FolderPreview.rowInset)
        .background(lit ? Omnibox.chosenFill : .clear, in: RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
    }
}

/// A line of a pin's card: a folder preview's row.
private struct PinLine: View {
    let item: PinItem
    let lit: Bool

    var body: some View {
        PreviewLine(title: item.title, detail: item.detail, strong: item.strong, lit: lit) {
            if let host = item.host { pinMark(host) }
        }
    }
}
