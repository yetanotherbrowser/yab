import AppKit
import EventKit
import SwiftUI
import WebKit

// A date written in a mail becomes an event (docs/mail.md, Calendar): the
// dates in a mail's own words underlined (MailDates), a click on one, or
// ⌘K's New Event, opening a line under the date (MailEventPop): its day,
// when and with whom, Add ↩, and ••• for the fuller form. It goes into the Mac's
// calendar when Yab may already write there, never asked by itself; into
// Google Calendar instead, guests asked by Google, for an account that gave
// `calendar.events` (none does yet: it is never asked for). ⌘Z in the
// corner takes it out again.

@MainActor
final class MailEvents: ObservableObject {
    static let shared = MailEvents()

    /// The event a mail's date made, as its card shows it.
    struct Card: Equatable {
        let account: String
        let thread: String
        /// The mail it is drawn under.
        let message: String
        var event: MailEvent
        var editing = false
        /// Who, as typed while editing: names or addresses, by commas.
        var who = ""
        var adding = false
        /// Said when it couldn't be added.
        var trouble: String?
        /// Where the date's words end, in the mail's words' own space: the
        /// arrow points up at it. Nil until measured: under the words.
        var anchor: CGPoint?
    }

    @Published var card: Card?

    /// A mail's words with their dates marked, and the dates.
    struct Dated {
        let html: String?
        let text: AttributedString?
        let found: [MailDates.Found]
    }

    /// Kept for the mails shown lately, by what changes what comes out: the
    /// mail, its words' length, its promises, and the day (a date goes
    /// once it is over).
    private var kept: [String: Dated] = [:]

    private init() {}

    private func key(_ message: MailDesk.Message) -> String {
        let day = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        return [message.id, "\(message.html?.utf8.count ?? -1)", "\(message.text.utf8.count)", message.promised.joined(separator: "\u{1F}"), "\(day)"]
            .joined(separator: "|")
    }

    /// Its words as the letter draws them, each date worth an event marked:
    /// the HTML, promises lit first, or the text.
    func dated(_ message: MailDesk.Message, html: Bool) -> Dated {
        let key = key(message) + (html ? "|h" : "|t")
        if let kept = kept[key] { return kept }
        let made: Dated
        if html, let page = message.html {
            let lit = message.promised.isEmpty ? page : MailHTML.lit(page, promised: message.promised)
            let marked = MailDates.marked(lit, sent: message.at)
            made = Dated(html: marked.html, text: nil, found: marked.found)
        } else {
            var text = MailHTML.litText(message.text, promised: message.promised)
            let found = MailDates.find(message.text, sent: message.at)
            for (n, date) in found.enumerated() {
                guard let range = Range(date.range, in: message.text), let marked = Range(range, in: text) else { continue }
                text[marked].link = URL(string: "\(MailDates.scheme):\(n)")
                text[marked].swiftUI.underlineStyle = Text.LineStyle(pattern: .solid, color: Color.accentColor.opacity(0.55))
            }
            made = Dated(html: nil, text: text, found: found)
        }
        if kept.count > 200 { kept.removeAll(keepingCapacity: true) }
        kept[key] = made
        return made
    }

    /// Whether the letter shows a mail's HTML (MailMessageView's rule).
    static func showsHTML(_ message: MailDesk.Message) -> Bool {
        guard let html = message.html else { return false }
        return message.quote == nil || html.contains("gmail_quote") || html.range(of: "<blockquote", options: .caseInsensitive) != nil
    }

    /// The thread's first date worth an event: in its newest mail that has
    /// one. What ⌘K's New Event takes.
    func first(in messages: [MailDesk.Message]) -> (message: String, index: Int)? {
        for message in messages.reversed() where !dated(message, html: MailEvents.showsHTML(message)).found.isEmpty {
            return (message.id, 0)
        }
        return nil
    }

    // MARK: - the line

    /// A click on a date in a mail of the open thread: its line under it,
    /// pointing at the date (`anchor`, or measured in the mail's HTML).
    func open(message id: String, index: Int, anchor: CGPoint? = nil) {
        let desk = MailDesk.shared
        guard let row = desk.open, let message = desk.messages.first(where: { $0.id == id }) else { return }
        let html = MailEvents.showsHTML(message)
        let found = dated(message, html: html).found
        guard found.indices.contains(index) else { return }
        let store = MailCenter.shared.engines[row.account]?.store
        let me = store.map { [$0.me] + $0.aliases } ?? []
        let event = MailEvent.make(subject: row.subject, date: found[index], people: desk.crowd, me: me,
                                   words: desk.messages.reversed().map(\.text), slot: MailSlots.hours.length)
        withAnimation(MailDesk.still ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.2)) {
            card = Card(account: row.account, thread: row.thread, message: id, event: event, anchor: anchor)
        }
        if anchor == nil, html, let view = MailBodyView.live.allObjects.first(where: { $0.message == id }) {
            MailEvents.measure(view, index: index) { [weak self] point in
                guard let point, var now = self?.card, now.message == id else { return }
                now.anchor = point
                self?.card = now
            }
        }
    }

    /// Where a date's mark is in a mail's web view: the foot of its first
    /// line, a little in from where it starts.
    static func measure(_ view: WKWebView, index: Int, done: @escaping (CGPoint?) -> Void) {
        let script = """
        (function(){var a=document.querySelector('a[href="\(MailDates.scheme):\(index)"]');if(!a)return null;\
        var r=a.getClientRects()[0]||a.getBoundingClientRect();return [r.left+Math.min(r.width/2,20),r.bottom+window.scrollY]})()
        """
        view.evaluateJavaScript(script) { value, _ in
            let point = (value as? [Double]).flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
            MainActor.assumeIsolated { done(point) }
        }
    }

    /// ⌘K's New Event: the thread's first date.
    func newEvent() {
        guard let first = first(in: MailDesk.shared.messages) else { return }
        open(message: first.message, index: first.index)
    }

    func close() {
        withAnimation(MailDesk.still ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.16)) { card = nil }
    }

    /// The line's thread still the one in front; otherwise it is let go.
    var live: Card? {
        guard let card, MailDesk.shared.screen == .thread, MailDesk.shared.open?.thread == card.thread else { return nil }
        return card
    }

    /// •••: the fuller form, or back to the line.
    func edit() {
        guard var card else { return }
        if card.editing { card.event.people = MailEvents.people(card.who, others: card.event.people) }
        card.editing.toggle()
        card.who = card.event.people.map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" }.joined(separator: ", ")
        self.card = card
    }

    /// Mail's keys while the line is up: ↩ adds it, esc puts it away.
    /// Words typed in the reply keep every key; typed in the form, all but those.
    func key(_ event: NSEvent, writing: Bool) -> Bool? {
        guard let card else { return nil }
        guard live != nil else { self.card = nil; return nil }
        if writing, !card.editing { return nil }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.isEmpty, event.keyCode == 53 { close(); return true }
        if flags.isEmpty, event.keyCode == 36 || event.keyCode == 76 { add(); return true }
        return writing ? false : nil
    }

    // MARK: - where it goes

    enum Place: Equatable {
        /// Google Calendar, the account's own: guests asked by Google.
        case google
        /// The Mac's calendar.
        case mac
        /// The Mac's calendar not asked yet: asked when you press Allow.
        case ask
        /// The Mac's calendar kept from Yab: System Settings lets it in.
        case denied
    }

    /// Kept at Connect: the account's consent gave `calendar.events`.
    static func writeKey(_ account: String) -> String { "mail.calendar.write.\(account)" }

    /// The bench's: where it goes, whatever the account and the Mac say.
    static var forced: Place?

    static func place(account: String) -> Place {
        if let forced { return forced }
        if MailCenter.kind(of: account) == .gmail, Store.settings.bool(forKey: writeKey(account)),
           MailCenter.shared.engines[account]?.gmail != nil { return .google }
        switch Meetings.status {
        case .fullAccess, .writeOnly: return .mac
        case .notDetermined: return .ask
        default: return .denied
        }
    }

    static let privacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    /// Add (↩): the event where it goes, then the corner says so with ⌘Z.
    func add() {
        guard var card = live, !card.adding else { return }
        if card.editing { card.event.people = MailEvents.people(card.who, others: card.event.people) }
        card.event.title = card.event.title.trimmingCharacters(in: .whitespaces)
        if card.event.title.isEmpty { card.event.title = "New Event" }
        if card.event.end <= card.event.start { card.event.end = card.event.start.addingTimeInterval(TimeInterval(MailSlots.hours.length) * 60) }
        switch MailEvents.place(account: card.account) {
        case .denied:
            NSWorkspace.shared.open(MailEvents.privacy)
            return
        case .ask:
            // Asked because you pressed Allow, never by itself.
            card.adding = true
            self.card = card
            Task { @MainActor in
                let granted = (try? await Meetings.requestAccess(EKEventStore())) == true
                guard var now = self.card, now.message == card.message else { return }
                now.adding = false
                self.card = now
                if granted { self.add() }
            }
            return
        case .mac:
            addToMac(card)
        case .google:
            card.adding = true
            self.card = card
            Task { @MainActor in await self.addToGoogle(card) }
        }
    }

    /// Who, as typed: each one an address, a name with one, or a name
    /// already on the event.
    static func people(_ typed: String, others: [MailPerson]) -> [MailPerson] {
        MailPerson.list(typed).compactMap { person in
            if person.address.contains("@") { return person }
            return others.first { $0.name.caseInsensitiveCompare(person.said) == .orderedSame }
        }
    }

    private func addToMac(_ card: Card) {
        let store = EKEventStore()
        let made = EKEvent(eventStore: store)
        let event = card.event
        made.title = event.title
        made.startDate = event.start
        made.endDate = event.end
        made.isAllDay = event.allDay
        if !event.place.isEmpty {
            made.location = event.place
            made.url = URL(string: event.place)
        }
        // The Mac's calendar can't ask anyone: whom it is with, in its notes.
        if !event.people.isEmpty { made.notes = "With " + event.people.map(\.header).joined(separator: ", ") }
        made.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(made, span: .thisEvent, commit: true)
        } catch {
            return failed(card, "Your calendar didn\u{2019}t take it")
        }
        added(event) {
            guard let gone = store.event(withIdentifier: made.eventIdentifier ?? "") else { return true }
            return (try? store.remove(gone, span: .thisEvent, commit: true)) != nil
        }
    }

    private func addToGoogle(_ card: Card) async {
        guard let gmail = MailCenter.shared.engines[card.account]?.gmail, let token = try? await gmail.token() else {
            return failed(card, "Google didn\u{2019}t answer. Try again")
        }
        var parts = URLComponents(url: MeetingsGoogle.events(gmail.base), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "sendUpdates", value: "all")]
        var request = URLRequest(url: parts.url!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: card.event.google())
        guard let (data, response) = try? await gmail.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = json["id"] as? String else {
            return failed(card, "Google Calendar didn\u{2019}t take it. Try again")
        }
        added(card.event) {
            // Taken out as it went in: the guests told it is off.
            var gone = URLComponents(url: MeetingsGoogle.events(gmail.base).appendingPathComponent(id), resolvingAgainstBaseURL: false)!
            gone.queryItems = [URLQueryItem(name: "sendUpdates", value: "all")]
            var request = URLRequest(url: gone.url!, timeoutInterval: 20)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            Task { _ = try? await gmail.session.data(for: request) }
            return true
        }
    }

    private func failed(_ card: Card, _ words: String) {
        guard var now = self.card, now.message == card.message else { return }
        now.adding = false
        now.trouble = words
        self.card = now
    }

    /// In: the line goes, the corner says so, and ⌘Z (or its Undo) takes
    /// it out.
    private func added(_ event: MailEvent, remove: @escaping () -> Bool) {
        close()
        let desk = MailDesk.shared
        let token = desk.rememberOther {
            let out = remove()
            if out { MailDesk.shared.say("Event removed", mark: "calendar") }
            return out
        }
        DispatchQueue.main.async {
            desk.browser?.toaster.pop("Added to Calendar", mark: "calendar", keys: ["⌘", "Z"], undo: { desk.takeBack(token) })
        }
    }
}

// MARK: - the line under the date

/// Where a mail's words are in its view: what the line hangs from.
struct MailEventWords: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// Where the event's line goes over a mail's words: under the date, its
/// arrow at the date, kept inside the words' width.
struct MailEventSpot: View {
    @ObservedObject var events: MailEvents
    let card: MailEvents.Card
    @State private var width: CGFloat = 0

    var body: some View {
        GeometryReader { space in
            let anchor = card.anchor ?? CGPoint(x: MailEventPop.arrowIn, y: space.size.height)
            let x = max(0, min(anchor.x - MailEventPop.arrowIn, space.size.width - width))
            MailEventPop(events: events, card: card, arrow: anchor.x - x)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .offset(x: x, y: anchor.y + MailEventPop.arrowTall + 2)
        }
    }
}

/// The event a date in a mail makes, on one line under the date: its day
/// on a small calendar's page, when, with whom and where, Add ↩, and •••
/// for the fuller form (title, time, people, place). A popover's frame:
/// inset 6, its curve that plus a button's.
struct MailEventPop: View {
    @ObservedObject var events: MailEvents
    let card: MailEvents.Card
    /// Where the arrow points, from the line's leading edge.
    let arrow: CGFloat

    /// The arrow's tip, in from the leading edge when there is room.
    static let arrowIn: CGFloat = 20
    static let arrowTall: CGFloat = 6
    /// The day's page, the invitation card's at a popover's size.
    static let tile: CGFloat = 28

    private var event: MailEvent { card.event }
    private var place: MailEvents.Place { MailEvents.place(account: card.account) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                MailDayTile(date: event.start, allDay: event.allDay)
                    .scaleEffect(MailEventPop.tile / CardFrame.well)
                    .frame(width: MailEventPop.tile, height: MailEventPop.tile)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: event.when(locale: AppDates.locale))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    if let second {
                        Text(verbatim: second)
                            .font(.system(size: 12))
                            .foregroundStyle(card.trouble == nil ? Palette.muted : Color.orange)
                    }
                }
                .lineLimit(1)
                .padding(.trailing, 4)
                Button { events.add() } label: {
                    HStack(spacing: 6) {
                        Text(primary)
                        KeyGlyphs(keys: "↩", size: 11.5, tint: nil).opacity(0.6)
                            .transaction { $0.animation = nil }
                    }
                }
                .buttonStyle(.yab(.primary, .small))
                .fixedSize()
                .disabled(card.adding)
                Button { events.edit() } label: { Symbol("ellipsis", size: 12, weight: .semibold) }
                    .buttonStyle(.yab(.quiet, .small, icon: .square))
                    .keyTip(card.editing ? "Fewer details" : "Edit the event")
            }
            if card.editing { form }
        }
        .padding(BarFrame.inset)
        .shapeFrame(Radius.floating)
        .overlay(alignment: .topLeading) {
            MailEventArrow()
                .frame(width: MailEventPop.arrowTall * 2, height: MailEventPop.arrowTall)
                .offset(x: max(Radius.floating, arrow - MailEventPop.arrowTall), y: -MailEventPop.arrowTall + 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New Event")
    }

    private var primary: String {
        switch place {
        case .ask: return "Allow Calendar"
        case .denied: return "Open Settings"
        case .mac, .google: return card.adding ? "Adding\u{2026}" : "Add"
        }
    }

    /// Under when: what went wrong, where the calendar is let in, or with
    /// whom and where.
    private var second: String? {
        if let trouble = card.trouble { return trouble }
        switch place {
        case .ask: return "Yab asks for your calendar first"
        case .denied: return "Allow Yab in Privacy & Security \u{203A} Calendars"
        case .mac, .google: return event.with
        }
    }

    private var form: some View {
        let edit = Binding<MailEvents.Card>(get: { events.card ?? card }, set: { events.card = $0 })
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: edit.event.title)
            HStack(spacing: 6) {
                DatePicker("Starts", selection: edit.event.start, displayedComponents: event.allDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden()
                Text(verbatim: "\u{2013}").foregroundStyle(Palette.muted)
                DatePicker("Ends", selection: edit.event.end, in: event.start..., displayedComponents: event.allDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden()
            }
            .environment(\.locale, AppDates.locale)
            TextField("People, by name or address", text: edit.who)
            TextField("Place or a call\u{2019}s link", text: edit.event.place)
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12.5))
        .frame(width: 320, alignment: .leading)
        // Under the words, past the page.
        .padding(.leading, MailEventPop.tile + 8)
    }
}

/// The popover's arrow up at the date: its ground, and its hairline on
/// the two sides that show.
private struct MailEventArrow: View {
    var body: some View {
        ZStack {
            Triangle().fill(Palette.ground) // design: the arrow carries on the popover's own frame, ground and hairline
            Triangle(open: true).stroke(Palette.hairline, lineWidth: 1)
        }
    }

    private struct Triangle: Shape {
        var open = false
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            if !open { path.closeSubpath() }
            return path
        }
    }
}
