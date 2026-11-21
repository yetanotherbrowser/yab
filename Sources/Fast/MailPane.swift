import AppKit
import SwiftUI
import WebKit

// MailDesk's native list, thread and compose surfaces. Between a list and
// thread only the list name morphs into the breadcrumb; all other content
// switches immediately. Other actions retain their existing motion.

struct MailPane: View {
    @ObservedObject var desk = MailDesk.shared
    @ObservedObject var list = MailList.shared
    @ObservedObject var center = MailCenter.shared
    @MailStill private var still
    @MailInstant private var instant

    /// The column the list and a thread share, one width: the
    /// list's rows and a thread's words on one edge, so a subject travels
    /// straight up into its head; narrower windows take all of the page.
    static let measure: CGFloat = 820
    static let gutter: CGFloat = 32

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                switch desk.screen {
                case .list:
                    MailListView(desk: desk, list: list, center: center)
                        .transition(MailPane.transition(.list, desk.move, way: desk.way, still: still, instant: instant))
                case .thread:
                    VStack(alignment: .leading, spacing: 0) {
                        MailCrumb(desk: desk)
                        ZStack {
                            // The letter in front, and those made ahead of J
                            // and K unseen beside it (MailDesk.ahead): one of
                            // them comes in by its place changing, already
                            // made and laid out; one made then comes in by
                            // its transition.
                            ForEach(desk.drawn) { drawn in
                                MailThreadView(desk: desk, list: list, letter: drawn.letter)
                                    .modifier(MailLetterPlace(place: drawn.place, move: desk.move, still: still, instant: instant))
                                    .transition(drawn.place == .front ? MailPane.letter(desk.move, way: desk.way, still: still, instant: instant) : .identity)
                                    .zIndex(drawn.place == .front ? 1 : 0)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipped()
                    }
                    // Quick Look's controller while it is up (MailLook), one
                    // for the thread's screen, not one made with each letter.
                    .background(MailLookSpot().frame(width: 0, height: 0))
                    .transition(MailPane.transition(.thread, desk.move, way: desk.way, still: still, instant: instant))
                case .compose:
                    MailComposeView(desk: desk)
                        .transition(MailPane.transition(.compose, desk.move, way: desk.way, still: still, instant: instant))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            // Mail's keys where the field says its own: a pill at the foot,
            // its right end still, only its words changing (MailFootPill).
            // A page made narrow, the chat's column beside it, keeps
            // Commands alone rather than a pill cut at its left end.
            .overlay(alignment: .bottomTrailing) {
                MailFootPills(desk: desk)
                    .padding(16)
            }

            // Only when there is more to say of them than their name, which
            // the mail says already: who they are, what is open between you,
            // a meeting, other threads.
            if desk.screen != .list, let person = desk.person,
               person.meeting != nil || !person.recent.isEmpty || person.card != nil || !person.open.isEmpty {
                // There with the letter it is of, or gone with it, at once:
                // it changes in the letter's own transaction (MailDesk.show).
                Group {
                    Rectangle().fill(Palette.hairline).frame(width: 1)
                    MailPersonRail(person: person)
                        .frame(width: 220)
                }
                .transition(.identity)
            }
        }
        .background(Palette.ground)
        .contentShape(Rectangle())
        // The morph's places (MailMorph): the pane's own points, and the
        // pane in its window.
        .coordinateSpace(.named(MailMorph.space))
        .background(MailPlace(kind: .pane))
        .background(MailSwipe { desk.swipeHistory($0) })
        // A thread or a new mail in front, or mail gone: a filter's menu with it.
        .onChange(of: desk.screen) { _, now in
            if now != .list { MailFilterMenu.shared.close() }
        }
        .onDisappear { MailFilterMenu.shared.close() }
        // Gone to in the launch's first seconds: mail starts now rather than
        // once the launch is over (AppStartup.meetingsAndMail).
        .onAppear { AppStartup.mailNow() }
    }

    /// In where the last screen stood, 4 pt up (or down, going back); out
    /// quicker, only fading. A change with nothing to morph, and mail held
    /// still by Reduce Motion, where the change has no animation: the new
    /// screen is simply there, the last one fading. With Animations off
    /// (`instant`) not even that: the last one is gone in the same frame.
    static func arrival(_ way: CGFloat, instant: Bool = false) -> AnyTransition {
        if instant { return .identity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: 4 * way)),
                           removal: .opacity.animation(.linear(duration: 0.1 * MailMorph.pace)))
    }

    /// List/thread changes are immediate; MailMorph moves their list name.
    /// Other changes retain their existing transitions.
    static func transition(_ screen: MailDesk.Screen, _ move: MailDesk.Move, way: CGFloat, still: Bool, instant: Bool = false) -> AnyTransition {
        if move == .cut || move == .open || move == .close { return .identity }
        if still { return arrival(way, instant: instant) }
        let pace = MailMorph.pace
        let wash = AnyTransition.modifier(active: MailWash(amount: 1), identity: MailWash(amount: 0))
        let washOut = wash.animation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.13 * pace))
        let washIn = wash.animation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.2 * pace).delay(0.05 * pace))
        let fadeOut = AnyTransition.opacity.animation(.linear(duration: 0.08 * pace))
        // The letter under its words from early on, under the card still
        // flying: never a frame with neither. In
        // place, not rising: its words land where it stands.
        let under = AnyTransition.opacity.animation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.2 * pace).delay(0.04 * pace))
        switch (move, screen) {
        case (.compose, .list): return .asymmetric(insertion: .identity, removal: washOut)
        case (.compose, _): return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.16 * pace).delay(0.12 * pace)), removal: washOut)
        case (.uncompose, .list): return .asymmetric(insertion: washIn, removal: fadeOut)
        // ⌘Z: the letter done or put off comes back in from the left.
        case (.restore, .thread):
            return .asymmetric(insertion: .opacity.combined(with: .offset(x: -56)).animation(MailMorph.spring(MailMorph.quick)), removal: fadeOut)
        case (.restore, _): return .asymmetric(insertion: .opacity, removal: fadeOut)
        // ⌘Z on a send: the surface grows back out of the corner (MailMorph)
        // over the letter or new mail coming up in place, where it lands.
        case (.unsend, .list): return .asymmetric(insertion: .opacity, removal: washOut)
        case (.unsend, _): return .asymmetric(insertion: under, removal: fadeOut)
        case (.uncompose, _): return .asymmetric(insertion: .opacity, removal: fadeOut)
        case (.list(let side), _):
            return .asymmetric(insertion: .opacity.combined(with: .offset(y: 22 * side)).animation(MailMorph.spring(MailMorph.quick, delay: 0.04)),
                               removal: .opacity.combined(with: .offset(y: -18 * side)).animation(.timingCurve(0.4, 0, 1, 1, duration: 0.1 * pace)))
        default: return arrival(way)
        }
    }

    /// One letter giving way to the next in the same place: J and K from
    /// the side the next lies on in the list, the old one up and away; a
    /// thread done or sent slides off to the left first.
    static func letter(_ move: MailDesk.Move, way: CGFloat, still: Bool, instant: Bool = false) -> AnyTransition {
        if move == .cut || move == .open || move == .close { return .identity }
        if still { return arrival(way, instant: instant) }
        let pace = MailMorph.pace
        switch move {
        case .step(let side):
            return .asymmetric(insertion: .opacity.combined(with: .offset(y: 26 * side)).animation(MailMorph.spring(MailMorph.quick, delay: 0.03)),
                               removal: .opacity.combined(with: .offset(y: -22 * side)).animation(.timingCurve(0.4, 0, 1, 1, duration: 0.11 * pace)))
        case .gone:
            return .asymmetric(insertion: .opacity.combined(with: .offset(y: 26)).animation(MailMorph.spring(MailMorph.quick, delay: 0.11)),
                               removal: .opacity.combined(with: .offset(x: -56)).animation(.timingCurve(0.4, 0, 1, 1, duration: 0.15 * pace)))
        // ⌘Z: the one gone to the left comes back from there; the one that
        // took its place goes back down. A sent one comes up in place, its
        // reply growing back into it out of the corner (MailMorph).
        case .restore, .unsend:
            let down = AnyTransition.opacity.combined(with: .offset(y: 26)).animation(.timingCurve(0.4, 0, 1, 1, duration: 0.11 * pace))
            if move == .unsend {
                return .asymmetric(insertion: .opacity.animation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.2 * pace).delay(0.04 * pace)), removal: down)
            }
            return .asymmetric(insertion: .opacity.combined(with: .offset(x: -56)).animation(MailMorph.spring(MailMorph.quick, delay: 0.05)),
                               removal: down)
        default:
            return arrival(way)
        }
    }

    /// When a thread was last written to, as the list says it.
    static func said(_ date: Date, waiting: Bool = false, now: Date = Date()) -> String {
        let days = Int(now.timeIntervalSince(date) / 86_400)
        if waiting { return days < 1 ? "today" : "\(days)d, no reply" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.englishFormatted(date: .omitted, time: .shortened) }
        // Days on the calendar, not spans of 24 hours: Monday's mail read on
        // Wednesday morning was Monday, though under 48 hours ago.
        let apart = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? days
        if apart == 1 { return "yesterday" }
        if apart > 1, apart < 7 { return date.formatted(AppDates.dateTime.weekday(.abbreviated)) }
        // Mail of another year, as old inbox threads and Gmail's finds are, says which.
        if !Calendar.current.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(AppDates.dateTime.month(.abbreviated).day().year())
        }
        return date.formatted(AppDates.dateTime.month(.abbreviated).day())
    }

    /// From when to when, both ends said one way ("30 Sep to 1 Oct"), where
    /// `said` would say one "30 Sep" and the other "Thu".
    static func saidRange(_ first: Date, _ last: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(first, inSameDayAs: last) { return said(first, now: now) }
        let thisYear = calendar.isDate(first, equalTo: now, toGranularity: .year) && calendar.isDate(last, equalTo: now, toGranularity: .year)
        let style: Date.FormatStyle = thisYear ? AppDates.dateTime.month(.abbreviated).day() : AppDates.dateTime.month(.abbreviated).day().year()
        return first.formatted(style) + " to " + last.formatted(style)
    }

    /// Each account's dot, when every account's mail is listed together.
    static func tint(_ account: String, among accounts: [String]) -> Color {
        let tints: [Color] = [.accentColor, .orange, .green, .teal, .yellow]
        return tints[max(0, accounts.firstIndex(of: account) ?? 0) % tints.count]
    }
}

extension View {
    /// The one surface on a mail screen, the reply or a new mail: the
    /// page's ground, a hairline, the page's own curve, and no shadow, since
    /// it is on the page, not over it. Written in, its line darkens and a
    /// faint ring says where the keys go.
    func mailSurface(focused: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
        return background(Palette.ground, in: shape)
            .overlay(shape.strokeBorder(focused ? Palette.ink.opacity(0.22) : Palette.hairline, lineWidth: 1))
            .background {
                RoundedRectangle(cornerRadius: Radius.surface + 4, style: .continuous) // design: the ring's curve is concentric with the surface's, 4 out
                    .fill(Palette.ink.opacity(focused ? 0.035 : 0))
                    .padding(-4)
            }
    }

    /// A reading column's width and its gutters, in the middle of the page.
    func mailColumn() -> some View {
        padding(.horizontal, MailPane.gutter)
            .frame(maxWidth: MailPane.measure, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

/// Out of the way of what travels: a strong blur, washing to the ground.
struct MailWash: ViewModifier {
    let amount: CGFloat
    func body(content: Content) -> some View {
        content
            .blur(radius: 10 * amount)
            .opacity(1 - amount)
    }
}

/// Mail's keys, said the way the field says its own (FieldFoot): one pill
/// on glass at the page's foot, what Return does now in words, the one
/// thing done most there, and Commands. Its right end never moves: a
/// screen change only changes its words, the width going from its left
/// end, and a key's plates never animate. Where the screen has buttons of
/// its own with their keys (a reply, a new mail, a reply ready under the
/// thread), it is Commands alone: Send ⌘↩ is said on Send.
/// The foot's pill, or Commands alone where the page is narrow; gone, its
/// place kept, while ⌘J's line stands at the page's foot: one thing there.
private struct MailFootPills: View {
    @ObservedObject var desk: MailDesk
    @ObservedObject private var line = TaskLine.shared

    var body: some View {
        let lined = line.tab != nil && line.tab == Agents.shared.browser?.mailPageTab?.id
        ViewThatFits(in: .horizontal) {
            MailFootPill(desk: desk)
            MailFootPill(desk: desk, commandsOnly: true)
        }
        .opacity(lined ? 0 : 1)
        .allowsHitTesting(!lined)
    }
}

struct MailFootPill: View {
    @ObservedObject var desk: MailDesk
    var commandsOnly = false
    @ObservedObject private var hotkeys = Hotkeys.shared
    @ObservedObject private var list = MailList.shared
    @MailStill private var still

    struct Item: Identifiable, Equatable {
        let id: String
        let words: String
        let keys: String
        var strong = false
    }

    static func items(_ desk: MailDesk) -> [Item] {
        var out: [Item] = []
        // A split being made: its two ways out, and your AI while it has only words.
        if desk.screen == .list, let made = MailList.shared.draft, MailList.shared.split == "draft" {
            if made.rules.isEmpty, !made.title.trimmingCharacters(in: .whitespaces).isEmpty, MailCenter.agentsAllowed, PlanText.any, !MailList.shared.making {
                out.append(Item(id: "make", words: "Make It with \(AgentSetupModel.shared.writer)", keys: "↩", strong: true))
            }
            out.append(Item(id: "keepsplit", words: "Keep Split", keys: Keymap.shared.text(.mailSend), strong: !made.rules.isEmpty))
            out.append(Item(id: "discard", words: "Discard", keys: "esc"))
            return out
        }
        switch desk.screen {
        case .list:
            if desk.rows.isEmpty {
                out = [Item(id: "new", words: "New Mail", keys: Keymap.shared.text(.mailNew), strong: true)]
            } else if !desk.selection.isEmpty {
                // Rows picked: what the keys do to all of them, not to the cursor's.
                let n = desk.selection.count
                out = [Item(id: "done", words: n == 1 ? "Mark Done" : "Mark \(n) Done", keys: Keymap.shared.text(.mailDone), strong: true),
                       Item(id: "remind", words: "Remind", keys: Keymap.shared.text(.mailRemind)),
                       Item(id: "label", words: "Label", keys: Keymap.shared.text(.mailLabel))]
            } else {
                out = [Item(id: "open", words: "Open", keys: "↩", strong: true),
                       Item(id: "done", words: "Mark Done", keys: Keymap.shared.text(.mailDone))]
            }
        case .thread:
            if desk.draft == nil, desk.ready.isEmpty {
                // ↩ answers everyone on it: "Reply" while that is one person.
                out = [Item(id: "reply", words: desk.crowded ? "Reply All" : "Reply", keys: Keymap.shared.text(.mailReplyAll), strong: true),
                       Item(id: "done", words: "Mark Done", keys: Keymap.shared.text(.mailDone))]
            }
        case .compose:
            break
        }
        return out + [Item(id: "commands", words: "Commands", keys: Keymap.shared.text(.mailCommands))]
    }

    var body: some View {
        let _ = hotkeys.version
        let items = MailFootPill.items(desk).filter { !commandsOnly || $0.id == "commands" || list.split == "draft" }
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button { run(item.id) } label: { FieldFoot.label(item.words, item.keys) }
                    .buttonStyle(FootButton(strong: item.strong))
                    .focusable(false)
                    .transition(.opacity.animation(still ? nil : .linear(duration: 0.14)))
            }
        }
        .padding(2)
        .background { FieldGlass(shape: Capsule()) }
        .fixedSize()
        .animation(still ? nil : .timingCurve(0.33, 1, 0.68, 1, duration: 0.2), value: items.map(\.id))
    }

    private func run(_ id: String) {
        switch id {
        case "new": desk.compose()
        case "open": if let row = desk.chosen { desk.show(row) }
        case "done": desk.done()
        case "remind": desk.field(.remind)
        case "label": desk.field(.label)
        case "reply": desk.reply(all: true)
        case "make": list.makeDraft()
        case "keepsplit": list.keepDraft()
        case "discard": list.discardDraft()
        default: desk.field(.commands)
        }
    }
}

// MARK: - the list

struct MailListView: View {
    @ObservedObject var desk: MailDesk
    @ObservedObject var list: MailList
    @ObservedObject var center: MailCenter
    /// An act on many on its way to Gmail (Get Me To Zero): said in the head.
    @ObservedObject private var going = MailGoing.shared
    @MailStill private var still

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            // No account, or the first one being read: the front door.
            // A list with nothing in it: its own empty state (MailEmpty).
            if drafting, desk.rows.isEmpty {
                MailDraftEmpty(draft: list.draft)
            } else if !center.connected, !center.opening.isEmpty {
                // The store being opened at launch (MailCenter.open): the
                // mail in a moment, no front door meanwhile.
                Spacer(minLength: 0)
            } else if !center.connected || desk.rows.isEmpty && center.status.values.allSatisfy({ $0.synced == nil }) && desk.query.isEmpty && desk.who == nil {
                MailFrontDoor(center: center, browser: desk.browser)
            } else if desk.rows.isEmpty {
                MailEmptyState(desk: desk, list: list, center: center)
            } else {
                rows
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A filter's menu over the rows, under the pill it hangs from.
        .overlayPreferenceValue(MailFilterAnchors.self) { anchors in
            MailFilterLayer(anchors: anchors, desk: desk, list: list)
        }
        // Needs you emptied by hand is said differently (MailEmptyMemory).
        .onAppear { MailEmptyMemory.shared.start() }
    }

    private var searching: Bool { desk.who != nil || !desk.query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var title: String {
        if let who = desk.who { return who.name.isEmpty ? who.address : who.name }
        return searching ? "Search" : desk.splitName
    }

    /// How the rows are grouped under headings: the split's own choice, or
    /// by stretches of time in a long list (MailListView.grouping).
    private var grouped: String? {
        if let saved { return saved.group }
        return searching ? nil : MailListView.grouping(list.split)
    }

    /// A list being made is on screen (MailList.draft).
    private var drafting: Bool { list.split == "draft" && list.draft != nil && !searching }

    /// The split on screen, or the one being made, when no search is over it.
    private var saved: MailList.Split? {
        if drafting { return list.draft }
        return searching ? nil : list.split(list.split)
    }

    /// A change to the split on screen: the draft's, or one in the column.
    private func update(_ edit: @escaping (inout MailList.Split) -> Void) {
        if drafting { list.editDraft(edit) } else if let saved { list.change(saved.id, edit) }
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            line
            if let saved {
                MailListHead(saved: saved, draft: drafting, desk: desk, list: list)
            } else if !searching {
                MailInboxHead(split: list.split, desk: desk, list: list)
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 8)
        // The thread's own column: its title stands where the list's did.
        .mailColumn()
    }

    private var line: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let saved {
                Symbol(saved.icon ?? (drafting ? "sparkles" : "magnifyingglass"), size: 16)
                    .foregroundStyle(saved.icon == nil && drafting ? Palette.faint : Palette.ink)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                // Its name is written where it is read: the draft's from the
                // first key, one of yours on a click.
                MailListTitle(title: saved.title, draft: drafting, making: list.making,
                              focusRequest: list.draftTitleFocus, fixed: saved.builtIn && !drafting) { words in
                    update { $0.title = words }
                } submit: {
                    if drafting, saved.rules.isEmpty { list.makeDraft() }
                }
                .mailPart("list:title")
                .mailFlying("list:title", desk)
            } else {
                MailType.title(title)
                    .mailPart("list:title")
                    .mailFlying("list:title", desk)
            }
            // The count at the head's own size and line, lighter and quieter:
            // smaller on the baseline it read as fallen.
            if !desk.rows.isEmpty {
                // All it holds, though only a page is read: a whole inbox counts here.
                MailType.count(desk.total)
                    .contentTransition(.numericText(value: Double(desk.total)))
                    .mailPart("list:count")
                    .mailFlying("list:count", desk)
            }
            // Rows picked, and what the list is narrowed to: a plate each,
            // esc on the one it takes off first, a click takes it off too.
            if !desk.selection.isEmpty {
                Button { desk.unselect() } label: { MailKeyed(words: "\(desk.selection.count) selected", keys: "esc") }
                    .buttonStyle(.yab(.secondary, .small))
                    .fixedSize()
            }
            if let only = desk.only, saved == nil {
                Button { desk.narrow(nil) } label: {
                    HStack(spacing: 6) {
                        Symbol("line.3.horizontal.decrease", size: 11)
                        if desk.selection.isEmpty { MailKeyed(words: only.name, keys: "esc") } else { Text(only.name) }
                    }
                }
                .buttonStyle(.yab(.secondary, .small))
                .fixedSize()
            }
            // Said only when something is wrong: quiet is the all clear.
            if let trouble = center.status.values.compactMap(\.trouble).first {
                Text(trouble).font(.system(size: 12)).foregroundStyle(Color.orange).lineLimit(1)
            } else if let line = going.line {
                // A bulk act Gmail is still hearing, until it has all of it.
                Text(line).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 12)
            if let who = desk.who {
                // With, from or to them: the search's word, in the head.
                MailHeadChoice(options: [("with", "With"), ("from", "From"), ("to", "To")], on: who.rel) { rel in
                    desk.who?.rel = rel
                }
            }
            if searching {
                Button { desk.keepSearch() } label: { Text("Keep as a Split") }
                    .buttonStyle(.yab(.quiet, .small))
                    .fixedSize()
            } else if let saved, !saved.rules.isEmpty {
                MailGrouping(saved: saved) { key in update { $0.group = key } }
            }
        }
        .frame(height: 28)
    }

    private var rows: some View {
        // Lazy rows can be built after the desk changes. Their positions,
        // headings and picked neighbours belong to the same list as the row.
        let snapshot = RowSnapshot(rows: desk.rows, selection: desk.selection, chosen: desk.sel,
                                   group: grouped, ghost: desk.ghost)
        return ScrollViewReader { reader in
            ThreadScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if desk.fresh > 0 {
                        Button { desk.takeFresh(); reader.scrollTo(desk.rows.first?.id) } label: {
                            Text("↑ \(desk.fresh) new")
                        }
                        .buttonStyle(.yab(.primary, .small))
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(snapshot.rows.enumerated()), id: \.element.id) { index, _ in
                            let context = snapshot.presentation(at: index)
                            let row = context.row
                            // One child per thread lets the lazy stack count rows
                            // without constructing every conditional section header.
                            VStack(alignment: .leading, spacing: 0) {
                                if let heading = context.heading {
                                    MailSection(title: heading)
                                }
                                MailListRow(row: row, chosen: context.chosen, picked: context.picked,
                                            waiting: list.split == "waiting" && !searching,
                                            dot: list.account == "all" && center.accounts.count > 1 && (searching || center.together.count > 1)
                                                ? MailPane.tint(row.account, among: center.accounts) : nil,
                                            work: list.working[row.id] != nil, landing: desk.flying.contains("row:" + row.id),
                                            lit: desk.query,
                                            joinsUp: context.joinsUp, joinsDown: context.joinsDown,
                                            picking: context.picking,
                                            pick: { desk.pick(row, at: index) },
                                            tool: { desk.rowTool($0, row: row, at: index) })
                                    .background { MailRowFlash(n: list.flashed[row.id] ?? 0) }
                                    .opacity(desk.ghost ? 0.4 : 1)
                                    // ⌘ picks it, ⇧ the run to it, a plain click opens it.
                                    .onTapGesture { desk.click(row, at: index) }
                                    // The end of what is read in sight: a page more.
                                    .onAppear { if index >= desk.rows.count - 20 { desk.more() } }
                            }
                            // Moved as one, in the change that moved it: the
                            // rows under one done closing up in its spring.
                            // The row's own transaction keeps its plate and
                            // words from animating, and without a group held
                            // its place still too, so they jumped up.
                            .geometryGroup()
                            .id(row.id)
                            .transition(MailListView.rowTransition(desk.move, desk.returning.contains(row.id), still: still,
                                                                   fold: desk.selection.count > 1 && desk.selection.contains(row.id) || desk.folding.contains(row.id)))
                        }
                    }
                    .scrollTargetLayout()
                    // A list beyond the inbox's: Gmail's older mail, said at its foot.
                    MailViewFoot(desk: desk, list: list)
                }
                // The rows' places for the morph, in here, where scrolling
                // doesn't move them; this, where it stands in the pane.
                // An agent's hand over its rows, in their coordinates (MailHand).
                .overlay(alignment: .topLeading) { MailHandView() }
                .coordinateSpace(.named(MailMorph.list))
                .mailPart("list:content")
                // The thread's column too, the rows' plates reaching 12 past
                // it: a row's words stand where the thread's do, and the
                // subject travels straight up to its head.
                .padding(.horizontal, MailPane.gutter - 12)
                .frame(maxWidth: MailPane.measure, alignment: .leading)
                .frame(maxWidth: .infinity)
                // Clear of the foot's pill.
                .padding(.bottom, FieldFoot.room)
            }
            .scrollBounceBehavior(.basedOnSize)
            // The list's top in sight: what came in there is seen, no pill
            // to say it (MailDesk.changed).
            .onScrollGeometryChange(for: Bool.self) { $0.visibleRect.minY + $0.contentInsets.top < 8 } action: { _, top in
                desk.listAtTop(top)
            }
            .modifier(MailListPosition(desk: desk))
            // esc: the list as it stood, its row where it was, for the
            // letter's words to land on (MailDesk.listPlace). Not
            // published: a scroll draws nothing else.
            .mailPart("list:scroll")
            .onChange(of: desk.sel) { _, at in
                if desk.rows.indices.contains(at) { reader.scrollTo(desk.rows[at].id) }
            }
        }
    }
}

private struct MailListPosition: ViewModifier {
    let desk: MailDesk

    @ViewBuilder func body(content: Content) -> some View {
        if case .list = desk.move {
            content
        } else {
            content.scrollPosition(Binding(get: { desk.listPlace }, set: { desk.listPlace = $0 }))
        }
    }
}

extension MailListView {
    /// A lazy row must never use its captured position in a newer list.
    /// Keep the values read together; callbacks still act on the live desk.
    struct RowSnapshot {
        let rows: [MailDesk.Row]
        let selection: MailSelection
        let chosen: Int
        let group: String?
        let ghost: Bool

        func presentation(at index: Int, now: Date = Date()) -> RowPresentation {
            let row = rows[index]
            return RowPresentation(row: row,
                                   heading: ghost ? nil : MailListView.heading(rows, at: index, by: group, now: now),
                                   chosen: index == chosen, picked: selection.contains(row.id),
                                   joinsUp: index > 0 && selection.contains(rows[index - 1].id),
                                   joinsDown: index + 1 < rows.count && selection.contains(rows[index + 1].id),
                                   picking: !selection.isEmpty)
        }
    }

    struct RowPresentation {
        let row: MailDesk.Row
        let heading: String?
        let chosen: Bool
        let picked: Bool
        let joinsUp: Bool
        let joinsDown: Bool
        let picking: Bool
    }

    /// `fold`: picked as it goes, with the rest picked: their plate fades
    /// where it stands, as one sheet, while the rows under it close up,
    /// instead of each row going left on its own.
    static func rowTransition(_ move: MailDesk.Move, _ back: Bool, still: Bool, fold: Bool = false) -> AnyTransition {
        if case .list = move { return .identity }
        if fold, !still {
            return .asymmetric(insertion: back ? .opacity.combined(with: .offset(x: -40)).animation(MailMorph.spring(MailMorph.travel, delay: 0.04)) : .opacity,
                               removal: .opacity.animation(.easeOut(duration: 0.12 * MailMorph.pace)))
        }
        return coming(back, still: still)
    }

    /// A row done, put off or woken: out to the left, the rows under it
    /// closing up; ⌘Z brings it back in from there (`back`). Held still
    /// (Reduce Motion, Animations off): in and out at once.
    static func coming(_ back: Bool, still: Bool) -> AnyTransition {
        if still { return .identity }
        return .asymmetric(insertion: back ? .opacity.combined(with: .offset(x: -40)).animation(MailMorph.spring(MailMorph.travel, delay: 0.04)) : .opacity,
                           removal: .opacity.combined(with: .offset(x: -40)).animation(.timingCurve(0.4, 0, 1, 1, duration: 0.14 * MailMorph.pace)))
    }

    /// A group's heading over its first row: who, or which day, and how
    /// many; nil within a group, or when the list doesn't group.
    static func heading(_ rows: [MailDesk.Row], at index: Int, by group: String?, now: Date = Date()) -> String? {
        guard let group, rows.indices.contains(index) else { return nil }
        let key = { (row: MailDesk.Row) -> String in
            switch group {
            case "sender": return row.who
            case "when": return MailListView.when(row.at, now: now)
            default: return MailPane.said(row.at).capitalized
            }
        }
        let here = key(rows[index])
        guard index == 0 || key(rows[index - 1]) != here else { return nil }
        let count = rows[index...].prefix { key($0) == here }.count
        return here + " · \(count)"
    }
}

extension MailListView {
    /// A long list's stretch of time, as its heading says it: Today,
    /// Yesterday, This Week, Earlier This Month, then the month ("September",
    /// "August 2025" in another year).
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return "Yesterday" }
        if days < 7 { return "This Week" }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return "Earlier This Month" }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return date.formatted(sameYear ? AppDates.dateTime.month(.wide) : AppDates.dateTime.month(.wide).year())
    }

    /// How a list no split of yours groups is grouped: the long ones that
    /// reach back months (Other, Archive, Sent, Done, a label's and the
    /// rest beyond the inbox) by stretches of time; Needs you, Waiting and
    /// Later stay one run, a week or less, their order the point.
    static func grouping(_ split: String) -> String? {
        split == MailSplit.other.rawValue || split == MailSplit.older.rawValue || MailGo.isView(split) ? "when" : nil
    }
}

/// A grouped list's headings, for the bench.
@MainActor
enum MailListHeadings {
    static func at(_ rows: [MailDesk.Row], _ index: Int, _ group: String?) -> String? { MailListView.heading(rows, at: index, by: group) }
}

/// A split, under its name: what it keeps, its rules as filters
/// (MailFilterBar: a pill a kind, + Add Filter, what the list is narrowed
/// to for now), where its new mail goes when it skips the inbox, what
/// your AI says matters in it now, and the pages kept with it.
private struct MailListHead: View {
    let saved: MailList.Split
    var draft = false
    @ObservedObject var desk: MailDesk
    @ObservedObject var list: MailList

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if list.making, draft {
                HStack(spacing: 6) {
                    MailThinking()
                    Text("\(AgentSetupModel.shared.writer) is reading who sends you this").lineLimit(1)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
                .transition(.opacity)
            } else if let why = saved.why, !why.isEmpty {
                HStack(spacing: 6) {
                    Symbol("sparkles", size: 11).foregroundStyle(Color.accentColor)
                    Text(why).lineLimit(1)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
            }
            if saved.mode == .skip, saved.on, !draft {
                MailSkipLine(desk: desk, list: list, id: saved.id)
            } else if saved.hidden, saved.on, !draft {
                // Ads and promos: kept out of the lists here, Gmail untouched.
                HStack(spacing: 6) {
                    Symbol("eye.slash", size: 11)
                    Text("Kept out of your lists on this Mac. Gmail keeps them in the inbox.").lineLimit(1)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
            }
            MailFilterBar(saved: saved, draft: draft, desk: desk)
            // What comes here, done as it comes (Routines, `on mail`).
            if !draft, !saved.hidden, saved.on { MailRoutineLine(split: saved) }
            if !draft, let line = list.summaries[saved.id]?.text {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Symbol("sparkles", size: 11)
                    Text(line).lineLimit(2)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Color.accentColor)
                .mailHeadCard()
                .transition(.opacity)
            }
            // Pages kept with it, once there are any (⌘K's Keep a Page with This Split).
            if !draft, saved.pages?.isEmpty == false { MailPages(saved: saved, desk: desk, list: list) }
        }
        .padding(.top, 8)
        .animation(MailDesk.still ? nil : .easeOut(duration: 0.2), value: list.summaries[saved.id]?.text)
        .animation(MailDesk.still ? nil : .easeOut(duration: 0.2), value: list.making)
        .task(id: saved.id + "|\(desk.rows.count)") { if !draft { list.summarize(saved.id) } }
    }
}

/// A routine on what comes to a split (docs/mail.md, Routines on a split's mail): When Mail
/// Comes… under its name until there is one, then what it does, in a line.
/// Set in one sentence, "When mail comes to Receipts, save the PDF to
/// Finance/2026 and add a row to Expenses.", the words changed in place, a
/// few to add with a click; asking each time unless told to run on its
/// own. Paying and sending wait for you either way.
private struct MailRoutineLine: View {
    let split: MailList.Split
    @ObservedObject private var routines = Routines.shared
    @State private var editing = false
    @State private var words = ""
    @State private var asks = true
    @FocusState private var focused: Bool

    private var routine: Routine? { routines.onMail(split.id) }

    var body: some View {
        if editing {
            editor
        } else if let routine {
            HStack(spacing: 6) {
                Symbol("arrow.triangle.2.circlepath", size: 11)
                Text("When mail comes: " + routine.prompt + (routine.may == "ask" ? " · Asks each time" : " · Runs on its own"))
                    .lineLimit(1)
                Button("Edit") { open(routine) }
                    .buttonStyle(.yab(.quiet, .small))
                    .fixedSize()
                Button(routine.off == true ? "Turn On" : "Turn Off") { routines.turn(routine.id, on: routine.off == true) }
                    .buttonStyle(.yab(.quiet, .small))
                    .fixedSize()
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.muted)
        } else {
            Button { open(nil) } label: {
                HStack(spacing: 6) {
                    Symbol("arrow.triangle.2.circlepath", size: 11)
                    Text("When Mail Comes\u{2026}")
                }
            }
            .buttonStyle(.yab(.quiet, .small))
            .fixedSize()
        }
    }

    private func open(_ routine: Routine?) {
        words = routine?.prompt ?? ""
        asks = routine.map { $0.may == "ask" } ?? true
        editing = true
        focused = true
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("When mail comes to")
                Text(split.title).fontWeight(.semibold)
                Text(",")
            }
            .font(.system(size: 13))
            .foregroundStyle(Palette.ink)
            TextField("save the PDF to Finance/2026 and add a row to Expenses", text: $words, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .focused($focused)
            HStack(spacing: 6) {
                ForEach(["save its PDF", "add a row to a sheet", "forward it to my accountant"], id: \.self) { more in
                    Button("+ " + more) { add(more) }
                        .buttonStyle(.yab(.quiet, .small))
                        .fixedSize()
                }
            }
            HStack(spacing: 10) {
                Picker("How", selection: $asks) {
                    Text("Ask me each time").tag(true)
                    Text("Run on its own").tag(false)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Text("Pay and Send always wait for you, whichever you pick.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Button {
                    routines.onMail(split: split.id, title: split.title, words: words, asks: asks, id: routine?.id)
                    editing = false
                } label: {
                    HStack(spacing: 6) {
                        Text("Save")
                        KeyGlyphs(keys: "⌘↩", size: 11.5, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.primary, .small))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    editing = false
                } label: {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        KeyGlyphs(keys: "esc", size: 11.5, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.quiet, .small))
                .keyboardShortcut(.cancelAction)
                if let routine {
                    Button("Remove") {
                        _ = routines.remove(routine.id)
                        editing = false
                    }
                    .buttonStyle(.yab(.quiet, .small))
                }
            }
            .fixedSize()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardFrame()
    }

    /// A few words more, after what is written, as the sentence goes on.
    private func add(_ more: String) {
        let now = words.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        words = now.isEmpty ? more : now + ", and " + more
    }
}

/// A card under a list's name (what sorting did, the day's line, an offer,
/// a split's summary): its plate as wide as the rows' plates under it, which
/// stand out of the head's words, its mark in their dot's column and its
/// words in their names'.
private struct MailHeadCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.accentColor.opacity(0.1)))
            .padding(.horizontal, -12) // design: out to the rows' plates, 12 out of the words as MailListRow pads them
    }
}

extension View {
    fileprivate func mailHeadCard() -> some View { modifier(MailHeadCard()) }
}

/// The inbox's own lists, under their name: Other says how many ads and
/// promos are kept out of it, a click from them; Archive what it holds.
/// Nothing for the rest: quiet is the all clear.
private struct MailInboxHead: View {
    let split: String
    @ObservedObject var desk: MailDesk
    @ObservedObject var list: MailList

    var body: some View {
        Group {
            if split == MailSplit.needs.rawValue, let sorted = list.sorted {
                // Once: what sorting did, in the summary's look, until Got It
                // (as the offers' buttons stand), a thread opened or a day gone.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Symbol("sparkles", size: 11)
                        Text(MailInboxHead.sorted(sorted, days: list.policy.days, gmailToo: list.split(MailSplits.ads)?.mode == .skip)).lineLimit(3)
                    }
                    .foregroundStyle(Color.accentColor)
                    Button("Got It") { list.doneSorting() }
                        .buttonStyle(.yab(.secondary, .small))
                        .fixedSize()
                        .padding(.leading, 20)
                }
                .mailHeadCard()
            } else if let offer = list.offer(over: split) {
                MailOfferCard(offer: offer, desk: desk, list: list)
                    .id(offer.id)
            } else if split == MailSplit.needs.rawValue, let first = list.today.first {
                // The day's line: what is dated, soonest first; a click to the
                // first, Got It (as the sorting card's) puts it away until
                // something new is dated in it.
                VStack(alignment: .leading, spacing: 8) {
                    Button { desk.go(MailSplit.needs.rawValue); MailDesk.shared.openThread(account: first.account, thread: first.thread) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Symbol("sparkles", size: 11)
                            Text(MailList.todayLine(list.today)).lineLimit(2).multilineTextAlignment(.leading)
                        }
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyTip("Open the first of them")
                    Button("Got It") { list.doneToday() }
                        .buttonStyle(.yab(.secondary, .small))
                        .fixedSize()
                        .padding(.leading, 20)
                }
                .mailHeadCard()
            } else if split == MailSplit.other.rawValue, let ads = list.split(MailSplits.ads), let count = list.counts[MailSplits.ads], count > 0 {
                HStack(spacing: 6) {
                    Symbol("megaphone", size: 11)
                    Text(ads.mode == .skip ? "\(count.formatted()) ads and promos skip the inbox"
                                           : "\(count.formatted()) ads and promos kept out of here").lineLimit(1)
                    Button { desk.go(MailSplits.ads) } label: { Text("Ads and Promos") }
                        .buttonStyle(.yab(.quiet, .small))
                        .fixedSize()
                }
            } else if split == MailSplit.older.rawValue {
                HStack(spacing: 6) {
                    Symbol("archivebox", size: 11)
                    Text(MailInboxHead.older(days: list.policy.days)).lineLimit(1)
                }
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Palette.muted)
        .padding(.top, 8)
    }

    /// The card over Needs you, once: "From your last week, 3 need you.
    /// 1,842 older threads wait in Archive and 412 ads and promos are kept
    /// out of here. Gmail stays as it is."
    static func sorted(_ sorted: MailList.Sorted, days: Int?, gmailToo: Bool = false) -> String {
        let from = days == 7 ? "From your last week, " : days == 30 ? "From your last month, " : ""
        let needs = sorted.needs == 1 ? "1 needs you." : "\(sorted.needs.formatted()) need you."
        var rest: [String] = []
        if sorted.older > 0 {
            rest.append(sorted.older == 1 ? "1 older thread waits in Archive" : "\(sorted.older.formatted()) older threads wait in Archive")
        }
        if sorted.ads > 0 { rest.append("\(sorted.ads.formatted()) ads and promos are kept out of here") }
        let tail = rest.isEmpty ? "" : " " + rest.joined(separator: " and ") + "."
        return from + needs + tail + (gmailToo ? "" : " Gmail stays as it is.")
    }

    /// Archive under its name: older than what, and that Gmail keeps them.
    static func older(days: Int?) -> String {
        let span = days == 7 ? "a week" : days == 30 ? "a month" : days.map { "\($0) days" } ?? "the window"
        return "Older than \(span): never counted, never told. Gmail keeps them in the inbox."
    }
}

/// An offer from what you did (MailOffers), in the summary's look: its
/// words with the name in bold, its button, and Not Now, which asks why
/// once, so the next offers are fewer or none of this kind. Nothing to
/// thank anyone for: a choice and it goes.
private struct MailOfferCard: View {
    let offer: MailOffer
    @ObservedObject var desk: MailDesk
    @ObservedObject var list: MailList
    @State private var asking = false

    private var said: AttributedString {
        var name = AttributedString(offer.words.name)
        name.font = Font.system(size: 12.5, weight: .semibold)
        return AttributedString(offer.words.before) + name + AttributedString(offer.words.after)
    }

    /// The first reason, in what the offer is about.
    private var notThis: String {
        switch offer.kind {
        case .label: return "Not This Label"
        case .mute: return "Not This Thread"
        default: return "Not This Sender"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Symbol(offer.icon, size: 11)
                Text(said).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Color.accentColor)
            HStack(spacing: 6) {
                if asking {
                    Button(notThis) { list.decline(offer, why: .sender) }
                        .buttonStyle(.yab(.secondary, .small))
                    Button("Fewer Like This") { list.decline(offer, why: .fewer) }
                        .buttonStyle(.yab(.secondary, .small))
                    Button("Never Suggest This") { list.decline(offer, why: .never) }
                        .buttonStyle(.yab(.quiet, .small))
                } else {
                    Button(offer.button) { desk.take(offer) }
                        .buttonStyle(.yab(.primary, .small))
                    // Asked once, about this Mac: Not Now is the answer, no why.
                    Button("Not Now") {
                        if offer.kind == .mailApp { list.decline(offer, why: .never) } else { asking = true }
                    }
                        .buttonStyle(.yab(.quiet, .small))
                }
            }
            .fixedSize()
            .padding(.leading, 20)
        }
        .mailHeadCard()
        .animation(Motion.quick, value: asking)
    }
}

/// A split that skips the inbox, under its name: its new mail is archived
/// as it comes, and today's, a click away in Archived Today.
private struct MailSkipLine: View {
    @ObservedObject var desk: MailDesk
    @ObservedObject var list: MailList
    let id: String

    var body: some View {
        HStack(spacing: 6) {
            Symbol("archivebox", size: 11)
            Text("Its new mail skips the inbox, archived as it comes").lineLimit(1)
            if let count = list.skippedToday[id], count > 0 {
                Button { desk.go(MailSplits.skipped) } label: { Text("\(count) archived today") }
                    .buttonStyle(.yab(.quiet, .small))
                    .fixedSize()
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Palette.muted)
    }
}

/// The name of a split, or of one being made, in its head: written in
/// place. A draft's has the keys from the start and asks what it keeps; one
/// of yours edits on a click; a built-in one's stays its own.
private struct MailListTitle: View {
    let title: String
    let draft: Bool
    let making: Bool
    let focusRequest: Int
    var fixed = false
    let set: (String) -> Void
    let submit: () -> Void
    @State private var words = ""
    @FocusState private var focus: Bool

    var body: some View {
        Group {
            if !fixed {
                // Keep the same field and font before and after focus; swapping
                // a Text for a TextField moved the heading's baseline.
                TextField("", text: $words, prompt: Text(draft ? "Name it, or say what it keeps" : "")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.muted))
                    .textFieldStyle(.plain)
                    .focused($focus)
                    .onChange(of: words) { _, now in if draft { set(now) } }
                    .onSubmit {
                        if !draft, !words.trimmingCharacters(in: .whitespaces).isEmpty { set(words) }
                        submit()
                    }
                    .onChange(of: focus) { _, on in if !on, !draft { words = title } }
                    .onAppear {
                        words = title
                        if draft { DispatchQueue.main.async { focus = true } }
                    }
                    .onChange(of: focusRequest) { _, _ in
                        if draft { DispatchQueue.main.async { focus = true } }
                    }
                    // Typing sets the title to the words; any other change (the AI's
                    // name, a rename elsewhere) is taken in.
                    .onChange(of: title) { _, now in if now != words { words = now } }
            } else {
                Text(title)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(Palette.ink)
        // As wide as its words (or what it asks), so the count stands beside it.
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 26)
        // AppKit reports a different first baseline while its field editor
        // is active. The heading keeps one baseline in both states.
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + NSFont.systemFont(ofSize: 20, weight: .semibold).descender }
    }
}

/// Where a draft's threads will stand, while there are none.
private struct MailDraftEmpty: View {
    let draft: MailList.Split?

    var body: some View {
        let ruled = !(draft?.rules.isEmpty ?? true)
        Text(ruled ? "Nothing in your inbox matches yet. Add who sends them, or take a filter off." : "Threads gather here as you add filters.")
            .font(.system(size: 13))
            .foregroundStyle(Palette.muted)
            .mailColumn()
            .padding(.top, 24)
    }
}

/// Three dots breathing: your AI at work.
private struct MailThinking: View {
    @State private var on = false
    @MailStill private var still

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { n in
                Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                    .opacity(still ? 1 : on ? 1 : 0.35)
                    .animation(still ? nil : .easeInOut(duration: 0.5).repeatForever().delay(Double(n) * 0.15), value: on)
            }
        }
        .onAppear { on = true }
    }
}

/// Pages kept with a split: a click looks at one over the list, Open All
/// opens them as tabs in the space you came from.
private struct MailPages: View {
    let saved: MailList.Split
    @ObservedObject var desk: MailDesk
    @ObservedObject var list: MailList

    var body: some View {
        HStack(spacing: 6) {
            Text("Pages").font(.system(size: 12)).foregroundStyle(Palette.muted)
            ForEach(saved.pages ?? [], id: \.url) { page in
                Button { if let url = URL(string: page.url) { desk.follow(url) } } label: {
                    HStack(spacing: 6) {
                        Symbol("globe", size: 11).foregroundStyle(Palette.muted)
                        Text(page.title).lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.wash))
                }
                .buttonStyle(.plain)
                .pointerTip(page.url)
                .contextMenu {
                    Button("Remove from the Split") { list.change(saved.id) { $0.pages?.removeAll { $0.url == page.url } } }
                }
            }
            Button { desk.field(adding: .page, to: saved.id) } label: {
                HStack(spacing: 4) {
                    Symbol("plus", size: 9, weight: .semibold)
                    Text(saved.pages?.isEmpty == false ? "Page" : "Keep a page with it")
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            if (saved.pages?.count ?? 0) > 1 {
                Button { desk.openPages(saved) } label: { Text("Open All as Tabs") }
                    .buttonStyle(.yab(.quiet, .small))
                    .fixedSize()
            }
        }
    }
}

/// How a split stands: by sender, by day, or one run.
private struct MailGrouping: View {
    let saved: MailList.Split
    let set: (String?) -> Void

    var body: some View {
        MailHeadChoice(options: [("sender", "Sender"), ("day", "Day"), ("", "Flat")], on: saved.group ?? "") { key in
            set(key.isEmpty ? nil : key)
        }
    }
}

/// A few words at the end of the list's head, one of them on: how a list
/// of yours is grouped, whether a person's search is with, from or to them.
private struct MailHeadChoice: View {
    let options: [(key: String, name: String)]
    let on: String
    let set: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.key) { key, name in
                let on = self.on == key
                Button { set(key) } label: {
                    Text(name)
                        .font(.system(size: 12))
                        .foregroundStyle(on ? Palette.ink : Palette.muted)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(on ? Palette.wash : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A heading between the list's groups.
private struct MailSection: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MailListRow: View {
    let row: MailDesk.Row
    let chosen: Bool
    /// Picked to act on with others (X, ⇧J, ⇧K): a tick where its dot is,
    /// the plate in the accent.
    var picked = false
    let waiting: Bool
    let dot: Color?
    /// An agent works on it (Do It): its end says what it is doing.
    let work: Bool
    /// The letter's words landing on it (esc, MailMorph): its own words and
    /// plate hidden until they are home.
    let landing: Bool
    /// The words the list is searched by, lit where they are found, as
    /// the search's own rows light them (MailSearch); none outside a search.
    let lit: String
    /// Picked with the row over or under it: one plate for the run, its
    /// corners only at the run's ends.
    var joinsUp = false
    var joinsDown = false
    /// Something in the list is picked: every row's ring shows.
    var picking = false
    /// The ring in the margin clicked: the row picked or let go.
    var pick: () -> Void = {}
    /// Done, Remind or Label from the tools under the pointer.
    var tool: (MailDesk.RowTool) -> Void = { _ in }
    @State private var hovering = false
    @MailStill private var still
    /// When a mark on it changed in sight, by what: a label's id (its chip
    /// grows in), "star" (S's star pops out), "dot" (unread's dot shrinks
    /// or grows). Played on their own clock (MailSince): the row's own
    /// transaction, which keeps it still, takes any animation away.
    @State private var since: [String: Date] = [:]

    var body: some View {
        // Its parts' places in the list's content, for the morph: a scroll
        // doesn't move them there.
        let id = "row:" + row.id
        HStack(spacing: 12) {
            Group {
                if let kept = row.kept {
                    Symbol(kept.kind == .draft ? "pencil" : kept.kind == .scheduled ? "paperplane" : "bookmark", size: 11)
                        .foregroundStyle(Palette.muted)
                } else {
                    // Unread, in the account's color when every account is listed;
                    // picked or not, the ring in the margin says that.
                    // U: read, it shrinks away; unread again, it grows back.
                    MailSince(since: since["dot"], spring: row.unread ? MailMorph.quick : MailMorph.gone) { way in
                        let shown = max(0.01, row.unread ? way : 1 - way)
                        Circle().fill(dot ?? Color.accentColor).frame(width: 6, height: 6)
                            .scaleEffect(shown)
                            .opacity(Double(min(1, shown)))
                    }
                        .mailPart(id + ":dot", listed: true)
                        .opacity(landing ? 0 : 1)
                }
            }
            .frame(width: row.kept == nil ? 8 : 14)
            MailType.who(row.who, unread: row.unread, lit: lit)
                .mailPart(id + ":who", listed: true)
                .opacity(landing ? 0 : 1)
                .frame(width: 136, alignment: .leading)
            HStack(spacing: 0) {
                ForEach(chips, id: \.id) { label in
                    MailSince(since: since[label.id], spring: MailMorph.quick) { MailLabelChip(label: label, grown: $0) }
                }
                MailType.subject(row.subject, lit: lit)
                    .mailPart(id + ":subject", listed: true)
                    .layoutPriority(1)
                // A cold pitch's no, ready to go with ⌘↩.
                if row.noReady {
                    Text(" · No ready").font(.system(size: 13)).foregroundStyle(Color.accentColor).lineLimit(1).fixedSize()
                }
                if !row.line.isEmpty {
                    MailType.gist(row.line, lit: lit)
                        .mailPart(id + ":gist", listed: true)
                }
            }
            .opacity(landing ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if let code = MailCodeState.shared.item(account: row.account, thread: row.thread) {
                    MailCodeRow(item: code)
                }
                Group {
                if work {
                    MailWork(account: row.account, thread: row.thread, size: 12)
                } else {
                    HStack(spacing: 6) {
                        // Files in it: a clip, before it is opened.
                        if row.attached { Symbol("paperclip", size: 11).foregroundStyle(Palette.muted) }
                        // Found by the server (Gmail, iCloud, Zoho Mail), not on this Mac until now: said quietly.
                        if row.gmail {
                            Text(MailCenter.shared.serverName(row.account)).font(.system(size: 12)).foregroundStyle(Palette.faint).lineLimit(1)
                        }
                        // Starred (S): a star before its time.
                        if row.starred {
                            MailSince(since: since["star"], spring: MailMorph.pop) { way in
                                Symbol("star", size: 11).foregroundStyle(Color.orange)
                                    .scaleEffect(0.3 + 0.7 * way)
                                    .opacity(Double(min(1, way * 2)))
                            }
                        }
                        // A reply an agent left under it, waiting for you to send.
                        if row.agentReady {
                            Text("Reply ready ·").font(.system(size: 12)).foregroundStyle(Color.accentColor).lineLimit(1)
                        }
                        // Sent and Waiting: your mail in it opened, in a word or two (MailReads).
                        if !row.opened.isEmpty {
                            Text(row.opened + " ·").font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        // A reminder if nobody answers, still waiting: when it comes back.
                        if !row.remind.isEmpty {
                            Text(row.remind + " ·").font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        // What is coming: an invitation's meeting, the day it names.
                        if !row.soon.isEmpty {
                            Text(row.soon + " ·").font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(row.soonLate ? Color.orange : Palette.muted).lineLimit(1)
                        }
                        MailType.when(row.when.isEmpty ? MailPane.said(row.at, waiting: waiting) : row.when,
                                      late: row.late || row.when.isEmpty && waiting && Date().timeIntervalSince(row.at) > 5 * 86_400)
                            .mailPart(id + ":when", listed: true)
                    }
                    .opacity(landing || showsTools ? 0 : 1)
                }
            }
            // Room for the three tools (24 pt each, 2 apart), so they stand
            // over the time and marks, never over a code before them.
            .frame(minWidth: 76, alignment: .trailing)
            // Under the pointer, over the row's end and in its width: the
            // row never moves for them (hover changes paint, never size).
            .overlay(alignment: .trailing) {
                if showsTools { MailRowTools(act: tool) }
            }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background {
            // The chosen row's plate: the letter's closing onto it stands in
            // for it until the words are home (MailMorph). Picked, in the
            // accent, a little more under the cursor, and one plate for a
            // run of them: square where the next one picked meets it.
            let r = Radius.control
            UnevenRoundedRectangle(topLeadingRadius: picked && joinsUp ? 0 : r, bottomLeadingRadius: picked && joinsDown ? 0 : r,
                                   bottomTrailingRadius: picked && joinsDown ? 0 : r, topTrailingRadius: picked && joinsUp ? 0 : r,
                                   style: .continuous)
                .fill(picked ? Color.accentColor.opacity(chosen ? 0.2 : 0.12)
                      : chosen && !landing ? Palette.wash : hovering ? Palette.hover : .clear)
        }
        .mailPart(id, listed: true)
        // Include the margin in hover and hit testing. An offset overlay
        // leaves the row's hover region on the way to its ring, hiding it.
        .padding(.leading, MailPickRing.hang)
        // The ring, hung in the page's margin left of the row, so nothing
        // in the row moves: under the pointer, on every row while any is
        // picked, filled on a picked one. A click picks without ⌘.
        .overlay(alignment: .leading) {
            if row.kept == nil, !landing {
                MailPickRing(picked: picked, shown: picked || picking || hovering, act: pick)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .padding(.leading, -MailPickRing.hang)
        .transaction { $0.animation = nil }
        // Put on while it is in sight (L, an agent, another device): grown,
        // a beat after it is drawn at nothing. Held still, simply there.
        .onChange(of: row.labels) { old, new in
            for id in Set(new).subtracting(old) { mark(id) }
        }
        .onChange(of: row.starred) { _, on in if on { mark("star") } }
        .onChange(of: row.unread) { _, _ in mark("dot") }
    }
}

extension MailListRow {
    /// A mark changed in sight: played from now, and let go once played,
    /// so nothing of it is drawn a frame more than it moves. Held still,
    /// simply there.
    func mark(_ key: String) {
        guard !still else { return }
        let now = Date()
        since[key] = now
        DispatchQueue.main.asyncAfter(deadline: .now() + MailMorph.marked * MailMorph.pace) {
            if since[key] == now { since[key] = nil }
        }
    }

    /// The person's labels on it as chips, two at most, not the one the
    /// list in front is of.
    var chips: [MailLabel] {
        let here = MailViews.label(MailList.shared.split)
        return Array(row.labels.compactMap { MailLabels.shared.chip($0, account: row.account) }.filter { $0.name != here }.prefix(2))
    }

    /// The tools stand over the row's end under the pointer: not on a draft
    /// or a send kept for later, not while an agent works on it, and while
    /// rows are picked only on those, which they act on together.
    var showsTools: Bool {
        hovering && !work && !landing && row.kept == nil && row.real && (!picking || picked)
    }
}

/// A label of the person's before a row's subject: Gmail's color as a dot,
/// the label's last name. `grown`: 0 at nothing, 1 whole.
private struct MailLabelChip: View {
    let label: MailLabel
    let grown: CGFloat

    var body: some View {
        MailBloom(amount: grown) {
            HStack(spacing: 4) {
                Circle().fill(MailLabelChip.tint(label.color)).frame(width: 6, height: 6)
                Text(label.name.split(separator: "/").last.map(String.init) ?? label.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Capsule().fill(Palette.ink.opacity(0.06)))
            .scaleEffect(0.85 + 0.15 * min(1, grown), anchor: .leading)
            .opacity(Double(min(1, max(0, grown))))
            .padding(.trailing, 6)
        }
        // Uncovered from its leading edge as it grows, never over the subject.
        .clipped()
    }

    static func tint(_ hex: String) -> Color { NSColor(hex: hex).map { Color(nsColor: $0) } ?? Palette.faint }
}

/// A mark's way from where it was to where it is, 0 to 1, by `spring`
/// from `since`, drawn every frame on its own clock while it plays; 1 when
/// nothing plays. A row's transaction, which holds it still, can't stop it.
private struct MailSince<Content: View>: View {
    let since: Date?
    let spring: (response: Double, damping: Double)
    @ViewBuilder let content: (CGFloat) -> Content
    var body: some View {
        if let since {
            TimelineView(.animation) { context in
                let time = max(0, context.date.timeIntervalSince(since)) / MailMorph.pace
                let curve = Spring(response: spring.response, dampingRatio: spring.damping)
                content(CGFloat(curve.value(fromValue: 0.0, toValue: 1.0, initialVelocity: 0, time: time)))
            }
        } else {
            content(1)
        }
    }
}

/// Its one view as wide as `amount` of its own width, from the leading
/// edge: 0 takes no room, 1 all of it.
private struct MailBloom: Layout {
    var amount: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let one = subviews.first else { return .zero }
        let size = one.sizeThatFits(.unspecified)
        return CGSize(width: size.width * max(0, amount), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let one = subviews.first else { return }
        one.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
    }
}

/// The ring a row is picked by with the pointer (MailListRow): hung left
/// of the row in the page's margin, an outline, filled in the accent with a
/// tick once picked.
private struct MailPickRing: View {
    let picked: Bool
    let shown: Bool
    let act: () -> Void
    /// How far left of the row's edge it hangs: its width and a gap.
    static let hang: CGFloat = 22
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            ZStack {
                Circle().strokeBorder(Palette.faint, lineWidth: 1.25).opacity(picked ? 0 : 1)
                Circle().fill(Color.accentColor).opacity(picked ? 1 : 0)
                Symbol("checkmark", size: 8, weight: .bold).foregroundStyle(.white).opacity(picked ? 1 : 0)
            }
            .frame(width: 15, height: 15)
            .frame(width: 20, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .opacity(shown ? (picked || hovering ? 1 : 0.6) : 0)
        .allowsHitTesting(shown)
        .onHover { hovering = $0 }
        .keyTip(picked ? "Deselect" : "Select", keys: "X")
        .accessibilityLabel(picked ? "Deselect" : "Select")
    }
}

/// Done, Remind and Label over a row's end under the pointer, each with
/// its key in the tip, as the keys E, H and L act.
private struct MailRowTools: View {
    let act: (MailDesk.RowTool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            one(.done, "checkmark", "Mark Done", .mailDone)
            one(.remind, "clock", "Remind Me", .mailRemind)
            one(.label, "tag", "Label", .mailLabel)
        }
    }

    private func one(_ tool: MailDesk.RowTool, _ symbol: String, _ title: String, _ key: Shortcut.Action) -> some View {
        Button { act(tool) } label: { Symbol(symbol, size: 12) }
            .buttonStyle(.yab(.quiet, .small, icon: .square))
            .focusable(false)
            .keyTip(title, keys: Keymap.shared.text(key))
            .accessibilityLabel(title)
    }
}

/// Under a row whose ready reply an agent just wrote or changed: the
/// accent comes up and fades, once each time, outside the row's own
/// transaction, which takes every animation off it.
private struct MailRowFlash: View {
    let n: Int
    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(Color.accentColor.opacity(on ? 0.14 : 0))
            .onChange(of: n) {
                on = true
                withAnimation(.easeOut(duration: 1.2).delay(0.25)) { on = false }
            }
    }
}

/// What an agent is doing on a thread (Do It), in its words, while it
/// works; nothing once it is done.
private struct MailWork: View {
    let account: String
    let thread: String
    let size: CGFloat
    @ObservedObject private var agents = Agents.shared

    var body: some View {
        if let work = MailList.shared.work(account, thread) {
            Text(work)
                .font(.system(size: size).monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .contentTransition(.opacity)
                .contentShape(Rectangle())
                // Its chat, in the column, rather than the row opening.
                .onTapGesture { MailChat.showWork(account, thread) }
                .pointerTip("Show the chat")
        }
    }
}

/// A person's round mark: their two letters.
struct MailAvatar: View {
    let initials: String
    let size: CGFloat
    var bad = false

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(bad ? Color(nsColor: .systemRed) : Color.accentColor)
            .frame(width: size, height: size)
            .background(Circle().fill((bad ? Color(nsColor: .systemRed) : Color.accentColor).opacity(0.14)))
    }
}

// MARK: - a thread

/// Above a thread and staying there while J and K change it: esc and the
/// list's name, and where in it the thread is.
private struct MailCrumb: View {
    @ObservedObject var desk: MailDesk
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            // esc and the list's name are a way back too, as the list's
            // own row in the column is: a click, the list.
            HStack(spacing: 8) {
                KeyGlyphs(keys: "esc", size: 11.5)
                    .foregroundStyle(Palette.muted)
                MailType.crumb(desk.crumbName)
                    .mailPart("crumb:name")
                    .mailFlying("crumb:name", desk)
            }
            .opacity(hovered ? 0.7 : 1)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture { desk.back() }
            Spacer()
            if let open = desk.open, let at = desk.rows.firstIndex(where: { $0.id == open.id }) {
                // J and K: only the number rolls; the crumb stays put.
                MailType.of(at + 1, desk.total)
                    .contentTransition(.numericText(value: Double(at)))
                    .animation(MailDesk.still ? nil : MailMorph.spring(MailMorph.quick), value: at)
                    .mailPart("crumb:of")
                    .mailFlying("crumb:of", desk)
            }
        }
        .frame(height: 48)
        .mailColumn()
    }
}

struct MailThreadView: View {
    @ObservedObject var desk: MailDesk
    @ObservedObject var list: MailList
    /// Its own words, as the pane handed them. One going out as another
    /// comes in (J and K, done, ⌘Z) or the list does is still drawn while
    /// it goes, with the desk already on the next: it shows them as they
    /// were before the change (MailDesk.leaving).
    let letter: MailDesk.Letter

    /// What stands in the thread, in order: whole mails, mails in one line,
    /// and the middle of a long thread in one line of its own.
    enum Entry: Identifiable {
        case whole(Int), line(Int), earlier(ClosedRange<Int>)
        var id: String {
            switch self {
            case .whole(let n): return "w\(n)"
            case .line(let n): return "l\(n)"
            case .earlier: return "earlier"
            }
        }
    }

    /// How far down the gist's dot stands: the middle of its first line.
    static var gistDrop: CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        return ((font.ascender - font.descender + font.leading) - 6) / 2
    }

    /// The entries as they stand: a mail whole, or the folded ones in a row
    /// gathered in one stack (MailFoldedStack), the thread's history between
    /// the mails that are open.
    enum Block: Identifiable {
        case whole(Int), stack([Entry])
        var id: String {
            switch self {
            case .whole(let n): return "w\(n)"
            case .stack(let entries): return "s" + (entries.first?.id ?? "")
            }
        }
    }

    static func blocks(_ entries: [Entry]) -> [Block] {
        var out: [Block] = []
        var stack: [Entry] = []
        for entry in entries {
            if case .whole(let n) = entry {
                if !stack.isEmpty { out.append(.stack(stack)) }
                stack = []
                out.append(.whole(n))
            } else {
                stack.append(entry)
            }
        }
        if !stack.isEmpty { out.append(.stack(stack)) }
        return out
    }

    /// Up to four mails: each but the last in a line, unless opened. More:
    /// the first whole, for what the thread is about, the middle in one
    /// line until opened, the two before the last in a line, the last whole.
    static func entries(_ messages: [MailDesk.Message], unfolded: Set<String>, earlierOpen: Bool, focus: Int?) -> [Entry] {
        let n = messages.count
        let open = { (i: Int) in i == n - 1 || unfolded.contains(messages[i].id) || focus == i }
        guard n > 4 else { return (0..<n).map { open($0) ? .whole($0) : .line($0) } }
        var out: [Entry] = [.whole(0)]
        if earlierOpen { out += (1...(n - 4)).map { open($0) ? .whole($0) : .line($0) } } else { out.append(.earlier(1...(n - 4))) }
        out += ((n - 3)..<n).map { open($0) ? .whole($0) : .line($0) }
        return out
    }

    var body: some View {
        // The one in front: a letter going out tells the morph nothing of
        // where its parts stand, as they are not the ones in front.
        let live = desk.open?.id == letter.open?.id
        let frozen = (!live || desk.changing) && desk.leaving?.open?.id == self.letter.open?.id
        let letter = frozen ? desk.leaving ?? self.letter : self.letter
        let messages = letter.messages
        ScrollViewReader { reader in
            ThreadScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    MailType.heading(letter.open?.subject ?? "")
                        .textSelection(.enabled)
                        .mailPart("heading", on: live)
                        .mailFlying("heading", desk)
                    if let line = letter.open?.line, !line.isEmpty {
                        // The words on the column's line, as the subject over
                        // them; the dot hangs left of it, as the focus capsule
                        // does, in the middle of the first line.
                        MailType.line(line)
                            .mailPart("gline", on: live)
                            .mailFlying("gline", desk)
                            .overlay(alignment: .topLeading) {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                                    .mailPart("gdot", on: live)
                                    .mailFlying("gdot", desk)
                                    .alignmentGuide(.leading) { $0[.leading] + 12 }
                                    .alignmentGuide(.top) { $0[.top] - MailThreadView.gistDrop }
                            }
                            .padding(.top, 4)
                    }
                    if letter.crowd.count > 1 {
                        MailCrowd(people: letter.crowd, desk: desk)
                            .padding(.top, 8)
                    }
                    // An invitation its mail carries: a card over the mail (MailCalendar).
                    ForEach(letter.invites, id: \.message) { card in
                        MailInviteCard(card: card, desk: desk, live: live)
                            .padding(.top, 16)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Rectangle().fill(Palette.hairline).frame(height: 1)
                        let entries = MailThreadView.entries(messages, unfolded: letter.unfolded, earlierOpen: letter.earlierOpen, focus: letter.focus)
                        ForEach(MailThreadView.blocks(entries)) { block in
                            switch block {
                            case .whole(let n):
                                MailMessageView(message: messages[n], index: n, count: messages.count, live: live, desk: desk).id(messages[n].id)
                            case .stack(let folded):
                                MailFoldedStack(entries: folded, messages: messages, live: live, landing: live && desk.flying.contains("first")) { n in
                                    desk.unfolded.insert(messages[n].id)
                                } openEarlier: {
                                    withAnimation(MailDesk.still ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.26)) { desk.earlierOpen = true }
                                }
                            }
                        }
                    }
                    .padding(.top, 16)
                    if let open = letter.open, list.working[open.id] != nil {
                        MailAgentBanner(account: open.account, thread: open.thread)
                            .padding(.top, 16)
                    }
                    // Ready or being written, one surface: the change between
                    // them is state, at once (P6), not motion.
                    Group {
                        if let draft = letter.draft {
                            MailReply(desk: desk, draft: draft, fresh: false, live: live)
                        } else if !letter.ready.isEmpty {
                            MailReady(desk: desk, ready: letter.ready, pick: letter.pick, replyTo: letter.replyTo, live: live)
                        }
                    }
                    .mailPart("reply", on: live)
                    .mailFlying("reply", desk)
                    .id("reply")
                    .padding(.top, 16)
                    .transition(.identity)
                }
                .padding(.bottom, FieldFoot.room)
                .mailColumn()
            }
            .scrollBounceBehavior(.basedOnSize)
            // Opened with its reply being written (⌘Z on a send, a send
            // set for later opened): there at once, where it was. Its own
            // reply: the desk may still hold the last letter's. A letter
            // made ahead, unseen, takes none of the desk's asks.
            .onAppear { if live, let draft = desk.draft, draft.thread == letter.open?.thread { reader.scrollTo("reply", anchor: .bottom) } }
            .onChange(of: desk.focusBody) { _, _ in
                guard live else { return }
                withAnimation(MailDesk.still ? nil : .default) { reader.scrollTo("reply", anchor: .bottom) }
            }
            .onChange(of: desk.focus) { _, at in
                if live, let at, desk.messages.indices.contains(at) {
                    withAnimation(MailDesk.still ? nil : .default) { reader.scrollTo(desk.messages[at].id, anchor: .center) }
                }
            }
            .overlay(alignment: .bottom) {
                // Mail that came while you read: said where you look, the
                // thread never moving under you.
                if let newer = letter.newer {
                    Button { desk.takeNewer() } label: {
                        HStack(spacing: 6) {
                            Symbol("arrow.down", size: 11)
                            Text(newer.count > 1 ? "\(newer.count) new, last from \(newer.from)" : "New from \(newer.from)")
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.ground)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(Palette.ink))
                    }
                    .buttonStyle(PressStyle(scale: ButtonSize.regular.pressed))
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
        }
    }
}

/// A letter's place among those drawn (MailDesk.drawn): the one in front,
/// or one made ahead, unseen where J or K brings it in from, the one J left
/// gone where it went. Changing places is J's and K's own motion
/// (MailPane.letter): in on the spring from the side it lies on, out
/// quicker the other way; held still, at once (Reduce Motion fading the
/// one going, as it fades a screen).
struct MailLetterPlace: ViewModifier {
    let place: MailDesk.Place
    let move: MailDesk.Move
    let still: Bool
    let instant: Bool

    func body(content: Content) -> some View {
        content
            .offset(y: still || move == .cut || move == .open || move == .close ? 0 : place == .after ? 26 : place == .before ? -22 : 0)
            .opacity(place == .front ? 1 : 0)
            .allowsHitTesting(place == .front)
            .accessibilityHidden(place != .front)
            .animation(motion, value: place)
    }

    private var motion: Animation? {
        if instant || move == .cut || move == .open || move == .close { return nil }
        if still { return place == .front ? nil : .linear(duration: 0.1 * MailMorph.pace) }
        guard place == .front else { return .timingCurve(0.4, 0, 1, 1, duration: 0.11 * MailMorph.pace) }
        return MailMorph.spring(MailMorph.quick, delay: move == .gone ? 0.11 : 0.03)
    }
}

/// What a thread shows, for the bench: "whole", "line" or "earlier" each.
@MainActor
enum MailThreadEntries {
    static func kinds(_ desk: MailDesk) -> [String] {
        MailThreadView.entries(desk.messages, unfolded: desk.unfolded, earlierOpen: desk.earlierOpen, focus: desk.focus).map { entry in
            switch entry {
            case .whole: return "whole"
            case .line: return "line"
            case .earlier(let range): return "earlier \(range.count)"
            }
        }
    }
}

/// Who is on the thread, under its head: three by name and how many more;
/// "and 3 more" opens them all as chips, with Copy All.
private struct MailCrowd: View {
    let people: [MailPerson]
    @ObservedObject var desk: MailDesk
    @State private var open = false

    var body: some View {
        if open {
            MailFlow(spacing: 6) {
                ForEach(people, id: \.address) { person in
                    MailChip(person: person, desk: desk)
                }
                MailCopy(value: people.map(\.header).joined(separator: ", ")) {
                    Text("Copy All").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink.opacity(0.75))
                }
                .frame(height: 24)
            }
            .transition(.opacity)
        } else {
            HStack(spacing: 4) {
                Text(people.prefix(3).map(\.said).joined(separator: ", "))
                    .lineLimit(1)
                if people.count > 3 {
                    Button { withAnimation(MailDesk.still ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)) { open = true } } label: {
                        Text("and \(people.count - 3) more").underline(color: Palette.muted.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.ink)
                } else {
                    Button { withAnimation(MailDesk.still ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)) { open = true } } label: {
                        Symbol("chevron.down", size: 9, weight: .semibold)
                    }
                    .buttonStyle(.plain)
                    .keyTip("Everyone on it")
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.muted)
        }
    }
}

/// A mail in full: who wrote it, with address actions on their name;
/// to whom, when it went to more than you; when; its
/// words, or its own HTML; the part it quotes behind •••.
private struct MailMessageView: View {
    let message: MailDesk.Message
    let index: Int
    /// Mails in its letter, and whether that letter is the one in front
    /// (MailThreadView.letter).
    let count: Int
    let live: Bool
    @ObservedObject var desk: MailDesk
    @ObservedObject private var events = MailEvents.shared
    @State private var pointer = CGPoint.zero
    @State private var senderHovering = false
    @State private var copyTip = KeyTipAnchor()

    private var quoted: Bool { desk.quotes.contains(message.id) }
    private var hasQuote: Bool {
        if message.quote != nil { return true }
        return message.html.map(htmlQuote) ?? false
    }

    private func htmlQuote(_ html: String) -> Bool {
        html.contains("gmail_quote") || html.range(of: "<blockquote", options: .caseInsensitive) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Menu {
                    Text(message.address)
                    Divider()
                    Button("Copy Email", mark: "yab.copyframe.at") { copySender(message.address) }
                    if !message.from.isEmpty {
                        Button("Copy Name", mark: "yab.copyframe.person") { copySender(message.from) }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        MailType.from(message.fromMe ? "You" : message.from, folded: false)
                            .mailPart("first", on: live && index == 0)
                            .mailFlying(live && index == 0 ? "first" : "", desk)
                        // Always laid out: hovering changes paint, never the header's width.
                        // Its frame's foot on the baseline stood it a point over
                        // the capitals' middle.
                        Symbol("chevron.down", size: 9, weight: .semibold)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            .foregroundStyle(Palette.muted)
                            .opacity(senderHovering ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                // The name on the column's line, as the words under it: the
                // plate hangs out past it, 6 from the ink each side (the
                // chevron's frame has 3 of its own), drawn outside the menu
                // so nothing of the menu's clips it.
                .hangingPlate(senderHovering, trailing: 3)
                .onHover { senderHovering = $0 }
                .disabled(message.address.isEmpty)
                .accessibilityLabel(message.fromMe ? "You" : message.from)
                .accessibilityHint("Sender options")
                if message.others {
                    Text("to " + message.to).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                MailType.when(MailPane.said(message.at))
                    .mailPart("last", on: live && index == count - 1)
                    .mailFlying(live && index == count - 1 ? "last" : "", desk)
            }
            if let thread = desk.open?.thread,
               let code = MailCodeState.shared.item(account: message.account, thread: thread), code.message == message.id {
                MailCodeBar(item: code, browser: desk.browser)
            }
            // Its own HTML, unless that only wraps words whose quoted part
            // the words alone can keep apart.
            // Dates worth an event underlined in them; one clicked, or ⌘K's
            // New Event, its line under the date (MailEvents).
            Group {
                if let html = message.html, message.quote == nil || htmlQuote(html) {
                    MailBody(html: events.dated(message, html: true).html ?? html,
                             quoted: quoted, browser: desk.browser, message: message.id, unseen: !live)
                } else {
                    // Your promises still open lit where you wrote them (MailPromise).
                    Text(events.dated(message, html: false).text ?? AttributedString(message.text))
                        .tint(Palette.ink)
                        .environment(\.openURL, OpenURLAction { url in
                            if let n = MailDates.index(url) {
                                events.open(message: message.id, index: n, anchor: CGPoint(x: pointer.x, y: pointer.y + 9))
                            } else { desk.follow(url) }
                            return .handled
                        })
                        .font(.system(size: 13.5))
                        .lineSpacing(7.5)
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Where a date was clicked: the line points there.
                        .onContinuousHover(coordinateSpace: .local) { if case .active(let at) = $0 { pointer = at } }
                }
            }
            // Its event's line hangs from here, drawn over the whole mail.
            .anchorPreference(key: MailEventWords.self, value: .bounds) { $0 }
            if hasQuote {
                if quoted, let quote = message.quote, !(message.html.map(htmlQuote) ?? false) {
                    Text(MailDesk.Message.unmarked(quote))
                        .font(.system(size: 13))
                        .lineSpacing(6)
                        .foregroundStyle(Palette.muted)
                        .textSelection(.enabled)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(Palette.hairline).frame(width: 2) }
                        .transition(.opacity)
                }
                Button {
                    withAnimation(MailDesk.still ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.2)) {
                        if quoted { desk.quotes.remove(message.id) } else { desk.quotes.insert(message.id) }
                    }
                } label: {
                    MailDots()
                }
                .buttonStyle(.plain)
                .keyTip(quoted ? "Hide the quoted mail" : "Show the quoted mail")
            }
            // Its files, a chip each (MailFileChips).
            if !message.files.isEmpty {
                MailFileChips(message: message, desk: desk)
                    .padding(.top, 4)
            }
            // Yours, gone with a read status: when it was opened, once it was.
            if let reads = message.reads, !reads.isEmpty {
                MailReadLine(seen: reads)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        // The mail the arrows are on: R answers this one.
        .overlay(alignment: .leading) {
            if desk.focus == index {
                Capsule().fill(Palette.ink).frame(width: 2).padding(.vertical, 16).offset(x: -14)
            }
        }
        .contentShape(Rectangle())
        // A date in it clicked, or ⌘K's New Event: its line under the date,
        // over the hairline, its files and the mails after it.
        .overlayPreferenceValue(MailEventWords.self) { words in
            if live, let words, let card = events.live, card.message == message.id {
                GeometryReader { space in
                    let rect = space[words]
                    MailEventSpot(events: events, card: card)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
                .transition(.opacity)
            }
        }
        .zIndex(events.card?.message == message.id ? 1 : 0)
    }

    private func copySender(_ value: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(value, forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        // The menu is gone and nothing on screen says it took: a tip where
        // the pointer let go, a moment. The name can't hold "Copied" in its
        // place as a chip does: "You" is narrower than it.
        let owner = copyTip
        KeyTip.shared.hover(owner, title: "Copied", shortcut: nil, side: .pointer, wait: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { KeyTip.shared.leave(owner) }
    }
}

/// Under a mail of yours that went with a read status (MailReads), in words
/// as mail's statuses are: "Opened 3× · last 2h ago". Apple Mail's privacy's
/// loads say maybe, and why under the pointer.
private struct MailReadLine: View {
    let seen: MailReads.Seen
    /// The pointer on the line, or on its card: the card stays up.
    @State private var over = false
    @State private var overCard = false
    @State private var card = false

    var body: some View {
        Text(MailReads.line(seen))
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Palette.muted)
            .lineLimit(1)
            .contentShape(Rectangle())
            // Under the pointer a moment: every open, where and when.
            .onHover { inside in
                over = inside
                settle()
            }
            .popover(isPresented: $card, arrowEdge: .bottom) {
                MailOpensCard(seen: seen)
                    .onHover { inside in
                        overCard = inside
                        settle()
                    }
            }
    }

    /// The card comes after a short rest on the line and goes a little
    /// after the pointer has left both, so the way onto it doesn't close it.
    private func settle() {
        let wanted = over || overCard
        DispatchQueue.main.asyncAfter(deadline: .now() + (wanted ? 0.35 : 0.25)) {
            if (over || overCard) == wanted, card != wanted { card = wanted }
        }
    }
}

/// Every open of a mail of yours, newest first (MailReads.Seen.opens):
/// where it was opened as the reader tells it (Gmail on any device, Apple
/// Mail's privacy a maybe, elsewhere), the time, and how long ago. No
/// names: one picture a mail can't tell who.
private struct MailOpensCard: View {
    let seen: MailReads.Seen
    private static let shown = 12

    var body: some View {
        let opens = seen.opens
        VStack(alignment: .leading, spacing: 0) {
            Text(opens.count == 1 ? "Opened once" : "Opened \(opens.count) times")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .padding(.bottom, 6)
            ForEach(Array(opens.prefix(Self.shown).enumerated()), id: \.offset) { _, open in
                HStack(spacing: 12) {
                    Text(MailReads.place(open.kind))
                        .foregroundStyle(open.kind == .apple ? Palette.muted : Palette.ink)
                        .frame(width: 112, alignment: .leading)
                    Text(MailPane.said(open.at))
                        .monospacedDigit()
                    Spacer(minLength: 16)
                    Text(MailReads.ago(open.at))
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                }
                .font(.system(size: 12.5))
                .lineLimit(1)
                .frame(height: 24)
            }
            if opens.count > Self.shown {
                Text("and \(opens.count - Self.shown) more")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .frame(minWidth: 260, alignment: .leading)
    }
}

/// The folded mails between two open ones, in one stack: the thread's
/// history, a quiet line each (who, their first words, when) and no
/// hairline between them. The names stand in one
/// column as wide as the widest of them, so "You" leaves no hole and the
/// words begin together. A long thread's middle is a line of its own, how
/// many more and who, opened in place; a click on a mail opens it where it is.
private struct MailFoldedStack: View {
    let entries: [MailThreadView.Entry]
    let messages: [MailDesk.Message]
    /// In the letter in front, and the thread's first mail travelling to it
    /// (its name is where the list row's lands, hidden while it flies).
    let live: Bool
    let landing: Bool
    let unfold: (Int) -> Void
    let openEarlier: () -> Void

    var body: some View {
        let column = Self.column(entries.map(name))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                switch entry {
                case .line(let n):
                    MailStackLine(name: name(entry), words: messages[n].text.replacingOccurrences(of: "\n", with: " "),
                                  when: MailPane.said(messages[n].at), column: column,
                                  first: live && n == 0, landing: landing && n == 0) { unfold(n) }
                        .id(messages[n].id)
                case .earlier(let range):
                    MailStackLine(name: name(entry), words: people(range),
                                  when: MailPane.saidRange(messages[range.lowerBound].at, messages[range.upperBound].at),
                                  column: column, quiet: true, action: openEarlier)
                case .whole:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .transition(.opacity.combined(with: .offset(y: 4)))
    }

    private func name(_ entry: MailThreadView.Entry) -> String {
        switch entry {
        case .line(let n): return messages[n].fromMe ? "You" : messages[n].from
        case .earlier(let range): return "\(range.count) more"
        case .whole: return ""
        }
    }

    /// Who wrote the middle, each once, in the order they wrote.
    private func people(_ range: ClosedRange<Int>) -> String {
        var seen = Set<String>()
        return messages[range].map { $0.fromMe ? "You" : $0.from }.filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    /// The names' column: the widest of them, 64 to 160.
    static func column(_ names: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let widest = names.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(160, max(64, ceil(widest) + 1))
    }
}

/// One line of the stack: the name in its column, the first words, when.
private struct MailStackLine: View {
    let name: String
    let words: String
    let when: String
    let column: CGFloat
    /// The middle's line: its name says how many, quieter than a sender.
    var quiet = false
    var first = false
    var landing = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(quiet ? Palette.muted : Palette.ink)
                .lineLimit(1)
                .mailPart("first", on: first)
                .opacity(landing ? 0 : 1)
                .animation(nil, value: landing)
                .frame(width: column, alignment: .leading)
            Text(words)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(when).font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted)
        }
        .frame(height: 28)
        .background(MailRowPlate(on: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

/// Over the reply while an agent does what the thread asks (Do It).
private struct MailAgentBanner: View {
    let account: String
    let thread: String
    @ObservedObject private var agents = Agents.shared

    var body: some View {
        if let work = MailList.shared.work(account, thread) {
            HStack(spacing: 8) {
                Symbol("agent.face", size: 13)
                Text(work).lineLimit(1)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Color.accentColor.opacity(0.1)))
            .contentShape(Rectangle())
            .onTapGesture { MailChat.showWork(account, thread) }
            .pointerTip("Show the chat")
        }
    }
}

// MARK: - the reply

/// The reply ready under the thread, before you write a word: greyer than
/// yours, its tabs 1, 2, 3 named for what each does, ⌘↩ sends it as it is,
/// ↩ writes in it, in the same place. Nothing is kept until you do.
private struct MailReady: View {
    @ObservedObject var desk: MailDesk
    /// Its letter's replies, the one picked and to whom (MailThreadView.letter).
    let ready: [MailDesk.Ready]
    let pick: Int
    let replyTo: [MailPerson]
    var live = true

    var body: some View {
        // Still drawn a moment while it goes, when nothing is ready any more.
        if let shown = ready.indices.contains(pick) ? ready[pick] : ready.first {
            card(ready, shown)
        }
    }

    private func card(_ ready: [MailDesk.Ready], _ shown: MailDesk.Ready) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("To").foregroundStyle(Palette.muted).frame(width: 24, alignment: .leading)
                ForEach(replyTo.prefix(2), id: \.address) { person in
                    MailChip(person: person, desk: desk)
                }
                if replyTo.count > 2 {
                    Text("+\(replyTo.count - 2)").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                if ready.count > 1 {
                    HStack(spacing: 2) {
                        ForEach(Array(ready.enumerated()), id: \.offset) { index, one in
                            Button { desk.pick = index } label: {
                                HStack(spacing: 6) {
                                    Text(one.label).lineLimit(1)
                                    if let action = Shortcut.numbered("mailPick", index + 1) {
                                        ShortcutGlyphs(action, size: 11, tint: nil).opacity(0.6)
                                    }
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(index == pick ? Palette.ink : Palette.muted)
                                .padding(.leading, 8)
                                .padding(.trailing, 4) // design: the key plate sits close to the edge (KeyPlate inset rule)
                                .frame(height: 26)
                                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                    .fill(index == pick ? Palette.wash : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .font(.system(size: 13))
            .padding(.leading, 16)
            .padding(.trailing, 8) // design: text on the surface's 16, a button at the end on its own 8
            .frame(minHeight: 40)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            Text(shown.text)
                .font(.system(size: 13.5))
                .lineSpacing(7.5)
                .foregroundStyle(Palette.ink.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .id(pick)
                .transition(.opacity)
                .contentShape(Rectangle())
                .onTapGesture { desk.reply() }
            HStack(spacing: 6) {
                MailWrittenBy(words: shown.by)
                // Its reminder if nobody answers, when it comes with one (mail_draft's remind_in).
                if let remind = shown.remind { MailRemindLine(until: remind) }
                // The files its snippet brings (mail_draft's snippet).
                if !shown.snippet.isEmpty { MailSnippetFilesLine(snippet: shown.snippet) }
                Spacer(minLength: 8)
                Button { desk.reply() } label: { MailKeyed(words: "Edit", action: .mailReplyAll) }.buttonStyle(.yab(.quiet)).fixedSize()
                Button { desk.send() } label: { MailKeyed(words: "Send", action: .mailSend) }.buttonStyle(.yab(.primary)).fixedSize()
                    .mailPart("send", on: live)
            }
            .padding(8)
            .padding(.leading, 8)
        }
        .mailSurface()
        .animation(MailDesk.still ? nil : .linear(duration: 0.12), value: pick)
    }
}

/// A mail's reminder if nobody answers, in a reply's or a new mail's foot:
/// "Remind me in 3 days if no reply", as quiet as the foot's other words.
private struct MailRemindLine: View {
    let until: Date
    var change: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Symbol("bell", size: 11)
            Text(MailFollowups.line(until)).lineLimit(1)
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.muted)
        .contentShape(Rectangle())
        .onTapGesture { change?() }
        .keyTip(change == nil ? "" : "Change the Reminder", keys: Keymap.shared.text(.mailRemindNoReply))
    }
}

/// Who wrote the words, while they are still theirs.
private struct MailWrittenBy: View {
    let words: String

    var body: some View {
        if !words.isEmpty {
            HStack(spacing: 6) {
                if words != "Your draft" { Symbol("agent.face", size: 12).foregroundStyle(Color.accentColor) }
                Text(words).lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .layoutPriority(-1)
        }
    }
}

/// A button's words and its keys (KeyGlyphs), the keys quieter.
private struct MailKeyed: View {
    let words: String
    let keys: String
    let action: Shortcut.Action?

    init(words: String, keys: String) {
        self.words = words
        self.keys = keys
        action = nil
    }

    init(words: String, action: Shortcut.Action) {
        self.words = words
        keys = ""
        self.action = action
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(words)
            if let action {
                ShortcutGlyphs(action, size: 11.5, tint: nil).opacity(0.6)
            } else {
                KeyGlyphs(keys: keys, size: 11.5, tint: nil, rest: 0.6)
            }
        }
    }
}

/// The reply, a forward or a new mail: the address it goes from when the
/// account has more than one (⇧⌘F), whom to (people, as chips), Cc and Bcc
/// when asked for, the subject of a new one or a forward (a reply's when
/// asked, ⇧⌘S), the words with their marks (MailWords), the signature under
/// them as it will go, its files as chips, the mail it answers or forwards
/// behind •••, and what to do with them. Space in empty words asks your AI
/// to write them; ⌘J writes them again. Files dropped anywhere on it, or a
/// picture pasted into its words, are attached.
private struct MailReply: View {
    @ObservedObject var desk: MailDesk
    let draft: MailDesk.Draft
    let fresh: Bool
    /// In the letter in front: one going out shows its own draft as it
    /// was, not the desk's, which is the next letter's.
    var live = true
    /// Over a page, from a mailto: link (MailtoCard): its addresses given,
    /// the words take the keyboard, and ⌘O goes on in mail's page.
    var outside = false
    /// The mail under the words shown (•••).
    @State private var quoted = false
    @FocusState private var subjectFocus: Bool
    /// Files dragged over it, or over its words (their own view).
    @State private var dropping = false
    @State private var droppingOnWords = false
    /// The snippets under the caret after ";" (MailSnippetPicker).
    @ObservedObject private var picker = MailSnippetPicker.shared
    /// How tall the words are: changed, the reply is laid out again, as
    /// the words alone don't tell it at each key.
    @State private var wordsTall: CGFloat = 0

    private var own: MailDesk.Draft { live ? desk.draft ?? draft : draft }
    /// The list after ";", when it is this draft's.
    private var call: MailSnippetPicker.Call? { live ? picker.call.flatMap { $0.draft == own.id ? $0 : nil } : nil }
    /// A row asked for in this draft (the desk's, while it is the one in front).
    private func asked(_ part: MailDesk.Part) -> Bool { live && desk.parts.contains(part) }
    /// A row asked to take the keyboard, each time.
    private func focusing(_ part: MailDesk.Part) -> Int? { live && desk.partFocus?.part == part ? desk.partFocus?.n : nil }
    private var hasCc: Bool { asked(.cc) || !own.cc.isEmpty }
    private var hasBcc: Bool { asked(.bcc) || !own.bcc.isEmpty }

    var body: some View {
        let senders = MailDesk.senders(of: own)
        VStack(alignment: .leading, spacing: 0) {
            if senders.count > 1 {
                MailFromRow(desk: desk, sender: MailSendAs.person(MailDesk.sending(of: own), senders, me: own.account), live: live)
            }
            MailRecipients(desk: desk, label: "To", header: Binding(get: { own.to }, set: { desk.draft?.to = $0; keep() }),
                           first: (fresh && !outside) || draft.to.isEmpty) {
                HStack(spacing: 2) {
                    if !hasCc {
                        Button("Cc") { desk.reveal(.cc) }
                            .buttonStyle(.yab(.quiet, .small))
                            .fixedSize()
                    }
                    if !hasBcc {
                        Button("Bcc") { desk.reveal(.bcc) }
                            .buttonStyle(.yab(.quiet, .small))
                            .fixedSize()
                            .keyTip("Add Bcc", keys: Keymap.shared.text(.mailBcc))
                    }
                }
            }
            .zIndex(3)
            if hasCc {
                MailRecipients(desk: desk, label: "Cc", header: Binding(get: { own.cc }, set: { desk.draft?.cc = $0; keep() }),
                               first: asked(.cc) && draft.cc.isEmpty, asked: focusing(.cc)) { hide(.cc, "Remove Cc") }
                    .zIndex(2)
                    .transition(.opacity)
            }
            if hasBcc {
                MailRecipients(desk: desk, label: "Bcc", header: Binding(get: { own.bcc }, set: { desk.draft?.bcc = $0; keep() }),
                               first: asked(.bcc) && draft.bcc.isEmpty, asked: focusing(.bcc)) { hide(.bcc, "Remove Bcc") }
                    .zIndex(1)
                    .transition(.opacity)
            }
            if fresh || own.forward || asked(.subject) {
                VStack(spacing: 0) {
                    // A new mail's subject is its head; a reply's and a forward's a row like the others.
                    TextField("Subject", text: Binding(get: { own.subject }, set: { desk.draft?.subject = $0; keep() }))
                        .textFieldStyle(.plain)
                        .font(.system(size: fresh ? 15 : 13, weight: fresh ? .medium : .regular))
                        .focused($subjectFocus)
                        .padding(.horizontal, 16)
                        .frame(height: fresh ? 44 : 40)
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                }
                .transition(.opacity)
                .onAppear { if focusing(.subject) != nil { DispatchQueue.main.async { subjectFocus = true } } }
            }
            ZStack(alignment: .topLeading) {
                MailWords(body: own.body, html: own.html, changed: { body, html in
                              desk.write(words: body, html: html)
                              keep()
                          }, focus: desk.focusBody, caret: desk.caret, toFirst: (fresh && !outside) || draft.to.isEmpty, live: live,
                          files: { desk.attach($0) }, picture: { desk.attach(picture: $0) },
                          dropping: { droppingOnWords = $0 }, moved: {
                              if desk.draftChip != nil { desk.chooseDraftChip(nil) }
                              if live { picker.look(in: desk.focusedWords, draft: desk.draft?.id) }
                          }, grew: { wordsTall = $0 }, tall: wordsTall)
                    .opacity(desk.asking == nil ? 1 : 0)
                    // The snippets after ";", hanging under it, inside the words' width.
                    .overlay(alignment: .topLeading) {
                        if let call {
                            MailSnippetPickerView(call: call) { picker.take($0) }
                                .offset(x: max(0, min(call.at.minX - 10, call.width - MailSnippetPickerView.width)), y: call.at.maxY + 4)
                                .transition(MailDesk.still ? .identity : .opacity.animation(.linear(duration: 0.11)))
                        }
                    }
                if desk.asking != nil {
                    MailAsk(desk: desk)
                } else if desk.writing {
                    Text("\(AgentSetupModel.shared.writer) is writing…")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.accentColor)
                } else if draft.body.isEmpty {
                    Text(own.forward ? "Add a note, or Space to ask \(AgentSetupModel.shared.writer)" : "Write, or Space to ask \(AgentSetupModel.shared.writer)")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.muted.opacity(0.7))
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // Over what follows, while the list after ";" hangs from it.
            .zIndex(call == nil ? 0 : 4)
            if let signature = MailDesk.signature(of: own) {
                MailSignatureLines(signature: signature)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
            if !own.files.isEmpty {
                MailDraftChips(desk: desk, files: own.files, live: live)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
            if !own.quote.isEmpty {
                MailUnder(quote: own.quote, forward: own.forward, open: $quoted)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            HStack(spacing: 6) {
                if !desk.why.isEmpty {
                    Text(desk.why).font(.system(size: 12)).foregroundStyle(Color.orange).lineLimit(1)
                } else if let big = MailAttach.tooBig(own.files) {
                    // Over Gmail's 25 MB: said before Send is pressed.
                    Text(big).font(.system(size: 12)).foregroundStyle(Color.orange).lineLimit(1)
                } else if let holes = MailSnippets.line(own.holes) {
                    // A snippet's place left to fill: it doesn't go until it is.
                    Text(holes).font(.system(size: 12)).foregroundStyle(Color.orange).lineLimit(1)
                } else if let remind = own.remind {
                    // Its reminder if nobody answers (⇧⌘H), quiet; a click
                    // changes it or takes it off.
                    MailRemindLine(until: remind) { desk.field(.followup) }
                    if !desk.writtenBy.isEmpty { MailWrittenBy(words: desk.writtenBy) }
                } else if !desk.writtenBy.isEmpty {
                    MailWrittenBy(words: desk.writtenBy)
                } else if desk.touched {
                    // What esc does, said before it is pressed.
                    Text("Kept as a draft if you leave").font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1).layoutPriority(-1)
                }
                Spacer(minLength: 8)
                if desk.asking != nil {
                    Button { desk.asking = nil } label: { MailKeyed(words: "Cancel", keys: "esc") }
                        .buttonStyle(.yab(.quiet)).fixedSize()
                    Button { desk.ask(desk.asking ?? "") } label: { MailKeyed(words: "Write", keys: "↩") }
                        .buttonStyle(.yab(.primary)).fixedSize()
                } else {
                    Button { desk.pickFiles() } label: { Symbol("paperclip", size: 12) }
                        .buttonStyle(.yab(.quiet, .regular, icon: .square))
                        .focusable(false)
                        .keyTip("Attach Files", keys: Keymap.shared.text(.mailAttach))
                    Button { desk.closeDraft() } label: { MailKeyed(words: "Close", keys: "esc") }.buttonStyle(.yab(.quiet)).fixedSize()
                    if outside {
                        Button { desk.browser?.keepMailto() } label: { MailKeyed(words: "Open in Mail", keys: "⌘O") }
                            .buttonStyle(.yab(.quiet)).fixedSize()
                    } else {
                        Button { desk.field(.rewrite) } label: { MailKeyed(words: "Rewrite", action: .mailRewrite) }.buttonStyle(.yab(.quiet)).fixedSize()
                            .disabled(draft.body.isEmpty || desk.writing)
                    }
                    Button { desk.send() } label: { MailKeyed(words: "Send", action: .mailSend) }.buttonStyle(.yab(.primary)).fixedSize()
                        .mailPart("send", on: live)
                }
            }
            .padding(8)
            .padding(.leading, 8)
        }
        .mailSurface(focused: true)
        // Files over any of it: the whole surface takes them, as the chat's
        // column does (ChatDropZone).
        .overlay {
            if live, dropping || droppingOnWords {
                ChatDropZone(title: "Drop to attach", detail: "Files and images, up to 25 MB in all")
                    .transition(.opacity)
            }
        }
        .animation(MailDesk.still ? nil : Motion.quick, value: dropping || droppingOnWords)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard live else { return false }
            MailReply.files(providers) { desk.attach($0) }
            return true
        }
        .onChange(of: focusing(.subject)) { _, asked in if asked != nil { subjectFocus = true } }
    }

    /// The files a drop holds, on the main thread once all are read.
    static func files(_ providers: [NSItemProvider], take: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [(Int, URL)] = []
        for (n, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock()
                    urls.append((n, url))
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let ordered = urls.sorted { $0.0 < $1.0 }.map(\.1)
            MainActor.assumeIsolated { if !ordered.isEmpty { take(ordered) } }
        }
    }

    /// Kept a moment after the last key, once the words are yours.
    private func keep() {
        Keeper.shared.soon { desk.save() }
    }

    /// A Cc or Bcc row's ×: the row away, its addresses with it.
    @ViewBuilder private func hide(_ part: MailDesk.Part, _ tip: String) -> some View {
        if live {
            Button { desk.conceal(part) } label: { Symbol("xmark", size: 8) }
                .buttonStyle(.yab(.quiet, .small, icon: .square))
                .focusable(false)
                .keyTip(tip, keys: part == .bcc ? Keymap.shared.text(.mailBcc) : nil)
        }
    }
}

/// The address a draft goes from, over whom it goes to, when its account
/// sends as more than one (MailSendAs): the name and the address; a click,
/// or ⇧⌘F, raises the field's From rows to choose another.
private struct MailFromRow: View {
    @ObservedObject var desk: MailDesk
    let sender: MailPerson
    let live: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button { if live { desk.field(.from) } } label: {
                HStack(spacing: 8) {
                    Text("From").foregroundStyle(Palette.muted)
                    if !sender.name.isEmpty {
                        Text(sender.name).foregroundStyle(Palette.ink).lineLimit(1).layoutPriority(1)
                    }
                    Text(sender.address)
                        .foregroundStyle(sender.name.isEmpty ? Palette.ink : Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Symbol("chevron.up.chevron.down", size: 9)
                        .foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13))
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyTip("Change From Address", keys: Keymap.shared.text(.mailFrom))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .mailPart("from", on: live)
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
    }
}

/// A draft's signature under its words, as it will go: its address's,
/// written in Gmail or in Settings › Mail, quiet, not written in here (⌘K's
/// Remove Signature takes it off this mail).
private struct MailSignatureLines: View {
    let signature: MailSignature

    var body: some View {
        let pieces = signature.pieces
        let unshown = pieces.filter { $0 == .unshown }.count
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .words(let words):
                    Text(words)
                        .font(.system(size: 13.5))
                        .lineSpacing(5)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                case .picture(let url, let width, let height):
                    MailSignaturePicture(url: url, width: width, height: height)
                case .unshown:
                    EmptyView()
                }
            }
            // A picture by cid:, whose bytes Gmail gives a signature no way
            // to fetch: said, not drawn as a hole.
            if unshown > 0 {
                Text(unshown == 1 ? "A picture in it isn’t shown: Gmail keeps it where Yab can’t fetch it."
                     : "\(unshown) pictures in it aren’t shown: Gmail keeps them where Yab can’t fetch them.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pointerTip("Your signature, as it goes")
    }
}

/// A picture of the signature, quiet as its words are: fetched once on a
/// session that keeps nothing (MailSignaturePictures), at the size its tag
/// gives, else its own, never wider than the column takes.
private struct MailSignaturePicture: View {
    let url: URL
    let width: Double?
    let height: Double?
    @ObservedObject private var pictures = MailSignaturePictures.shared

    var body: some View {
        let size = pictures.size(url, width: width, height: height)
        Group {
            if let image = pictures.images[url] {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                // Its room kept while it comes, so the words under it don't move.
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height, alignment: .leading)
        .opacity(0.8)
        .task(id: url) { await pictures.load(url) }
    }
}

/// The signatures' pictures, each fetched once and kept in memory while
/// Yab runs: by mail's own kind of session (no cookie, no cache on disk,
/// MailWire), the bytes of a data: address read as they are, 2 MB at most.
@MainActor
final class MailSignaturePictures: ObservableObject {
    static let shared = MailSignaturePictures()
    @Published private(set) var images: [URL: NSImage] = [:]
    private var asked: Set<URL> = []
    private let session = URLSession(configuration: MailWire.configuration())

    func load(_ url: URL) async {
        guard asked.insert(url).inserted else { return }
        var data: Data?
        if url.scheme?.lowercased() == "data" {
            data = try? Data(contentsOf: url)
        } else if let (got, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 {
            data = got
        }
        guard let data, data.count <= 2 << 20, let image = NSImage(data: data) else { return }
        images[url] = image
    }

    /// The room a picture takes: its tag's size where it gives one, else its
    /// own, both kept to 240 by 120 at most, its shape kept.
    func size(_ url: URL, width: Double?, height: Double?) -> CGSize {
        let own = images[url]?.size
        var size = CGSize(width: width ?? own?.width ?? 96, height: height ?? own?.height ?? 32)
        if let width, height == nil, let own, own.width > 0 { size.height = width * own.height / own.width }
        if let height, width == nil, let own, own.height > 0 { size.width = height * own.width / own.height }
        let scale = min(1, 240 / max(size.width, 1), 120 / max(size.height, 1))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// The mail a reply answers or a forward passes on, under the words as it
/// will go: behind ••• as a mail's quote is in the thread, its words on a
/// click, not to be written in.
private struct MailUnder: View {
    let quote: String
    let forward: Bool
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if open {
                Text(MailDesk.Message.unmarked(quote))
                    .font(.system(size: 13))
                    .lineSpacing(6)
                    .foregroundStyle(Palette.muted)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(Palette.hairline).frame(width: 2) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            Button {
                withAnimation(MailDesk.still ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.2)) { open.toggle() }
            } label: {
                MailDots()
            }
            .buttonStyle(.plain)
            .keyTip(open ? (forward ? "Hide the forwarded mail" : "Hide the quoted mail")
                         : (forward ? "Show the forwarded mail" : "Show the quoted mail"))
        }
    }
}

/// A draft's files under its words, a chip each as a thread shows a mail's:
/// the Finder's mark for its kind, its name cut in the middle (its kind
/// stays), its size, and × to take it off. A click chooses one; ⌫ takes
/// the chosen one off (MailDesk.take).
private struct MailDraftChips: View {
    @ObservedObject var desk: MailDesk
    let files: [MailDraftFile]
    /// In the letter in front: one going out is only shown.
    let live: Bool

    var body: some View {
        MailChipFlow(spacing: 6) {
            ForEach(files, id: \.id) { file in
                MailDraftChip(desk: desk, file: file, chosen: live && desk.draftChip == file.id, live: live)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One of them: chosen, a ring, as a thread's chip has it.
private struct MailDraftChip: View {
    @ObservedObject var desk: MailDesk
    let file: MailDraftFile
    let chosen: Bool
    let live: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        HStack(spacing: 8) {
            Image(nsImage: MailFiles.icon(file.type))
                .resizable()
                .frame(width: 16, height: 16)
            Text(file.name)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(file.said)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Palette.muted)
            Button { if live { desk.detach(file.id) } } label: { Symbol("xmark", size: 8) }
                .buttonStyle(.yab(.quiet, .small, icon: .square))
                .focusable(false)
                .keyTip("Remove", keys: "⌫")
        }
        .font(.system(size: 12.5))
        .padding(.leading, 10)
        .padding(.trailing, 3) // design: the × as far from the chip's end as from its top and bottom
        .frame(height: 30)
        .background(shape.fill(Palette.wash))
        .overlay(shape.fill(Palette.ink.opacity(hovering || chosen ? 0.04 : 0)).allowsHitTesting(false))
        .overlay(shape.strokeBorder(Palette.ink.opacity(chosen ? 0.22 : 0), lineWidth: 1).allowsHitTesting(false))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture { if live { desk.chooseDraftChip(file.id) } }
        .pointerTip(file.name + " · " + file.said)
    }
}

/// Space in an empty reply: what to ask your AI, in any words; ↩ and it
/// writes the reply in place, esc and you write it.
private struct MailAsk: View {
    @ObservedObject var desk: MailDesk
    @FocusState private var focus: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Ask \(AgentSetupModel.shared.writer):").foregroundStyle(Color.accentColor)
            TextField("what to answer, in any words", text: Binding(get: { desk.asking ?? "" }, set: { desk.asking = $0 }))
                .textFieldStyle(.plain)
                .focused($focus)
        }
        .font(.system(size: 13.5))
        .onAppear { DispatchQueue.main.async { focus = true } }
    }
}

/// A draft written to the store once typing pauses.
@MainActor
private final class Keeper {
    static let shared = Keeper()
    private var timer: Timer?
    func soon(_ run: @escaping @MainActor () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in MainActor.assumeIsolated { run() } }
    }
}

// MARK: - people in a field

/// Whom a mail goes to, as people: a chip each and room to type. Words
/// bring the people you write with most under it; ↩ or ⇥ takes the lit
/// one, a comma or a paste takes addresses as they are. ⌫ in the empty
/// field chooses the last chip, again takes it away; ⌘C on a chosen one
/// copies its address. A chip that isn't an address is red, and says so
/// under the pointer; nothing more is said of it.
private struct MailRecipients<Trailing: View>: View {
    @ObservedObject var desk: MailDesk
    let label: String
    @Binding var header: String
    var first = false
    /// Asked to take the keyboard (⇧⌘B), once for each number.
    var asked: Int? = nil
    @ViewBuilder let trailing: () -> Trailing
    @State private var typed = ""
    @State private var lit = 0
    @State private var chosen: String?
    @FocusState private var focus: Bool
    @MailStill private var still

    private var people: [MailPerson] { MailPerson.list(header) }

    private var found: [MailDesk.Contact] {
        guard focus else { return [] }
        return desk.people(matching: typed, limit: 4, leaving: Set(people.map(\.address)))
    }

    var body: some View {
        let found = self.found
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .foregroundStyle(Palette.muted)
                    .frame(width: 24, height: 24, alignment: .leading)
                MailFlow(spacing: 6) {
                    ForEach(people, id: \.address) { person in
                        MailChip(person: person, chosen: chosen == person.address, desk: desk) { remove(person) }
                    }
                    TextField(people.isEmpty ? "Name or address" : "", text: $typed)
                        .textFieldStyle(.plain)
                        .focused($focus)
                        .frame(minWidth: 120)
                        .frame(height: 24)
                        .onKeyPress(phases: .down) { press in keyed(press, found) }
                        .onSubmit { enter(found) }
                        .onChange(of: typed) { _, now in changed(now) }
                }
                trailing()
                    .frame(height: 24)
            }
            .font(.system(size: 13))
            .padding(.leading, 16)
            .padding(.trailing, 8) // design: text on the surface's 16, a button at the end on its own 8
            .padding(.vertical, 8)
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
        .overlay(alignment: .topLeading) {
            if !found.isEmpty {
                MailSuggestions(found: found, lit: min(lit, found.count - 1), typed: typed, light: { lit = $0 }) { take(found[$0]) }
                    .offset(x: 42, y: 44)
                    .transition(still ? AnyTransition.identity
                                : .asymmetric(insertion: .scale(scale: 0.98, anchor: .topLeading).combined(with: .opacity).animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.16)),
                                              removal: .opacity.animation(.linear(duration: 0.11))))
            }
        }
        .onChange(of: found.isEmpty) { _, none in desk.suggesting = !none }
        .onChange(of: chosen) { _, now in desk.chosenChip = now }
        .onChange(of: focus) { _, on in if !on { chosen = nil; desk.suggesting = false } }
        .onChange(of: asked) { _, now in if now != nil { focus = true } }
        .onAppear { if first { DispatchQueue.main.async { focus = true } } }
    }

    private func keyed(_ press: KeyPress, _ found: [MailDesk.Contact]) -> KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        switch press.key {
        case .downArrow where !found.isEmpty:
            lit = (lit + 1) % found.count
        case .upArrow where !found.isEmpty:
            lit = (lit - 1 + found.count) % found.count
        case .tab where !found.isEmpty:
            take(found[min(lit, found.count - 1)])
        case .delete where typed.isEmpty:
            guard let last = people.last else { return .ignored }
            if chosen == last.address { remove(last) } else { chosen = last.address }
        default:
            if press.characters == "," {
                commit(typed)
                return .handled
            }
            chosen = nil
            return .ignored
        }
        return .handled
    }

    private func enter(_ found: [MailDesk.Contact]) {
        if !found.isEmpty { take(found[min(lit, found.count - 1)]) } else { commit(typed) }
    }

    /// Typed or pasted with commas in it: each whole address a chip, the
    /// rest left to type on.
    private func changed(_ now: String) {
        lit = 0
        guard now.contains(where: { ",;\n".contains($0) }) else { return }
        let parts = now.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
        commit(parts.dropLast().joined(separator: ","))
        typed = parts.last?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private func commit(_ words: String) {
        // An address you write to already comes with its name.
        let more = MailPerson.list(words.replacingOccurrences(of: ";", with: ",")).map { person in
            person.name.isEmpty ? MailPerson(name: desk.name(of: person.address), address: person.address) : person
        }
        typed = ""
        guard !more.isEmpty else { return }
        set(people + more.filter { one in !people.contains { $0.address == one.address } })
    }

    private func take(_ contact: MailDesk.Contact) {
        typed = ""
        lit = 0
        set(people + [MailPerson(name: contact.name, address: contact.address)])
    }

    private func remove(_ person: MailPerson) {
        chosen = nil
        withAnimation(MailDesk.still ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.18)) {
            set(people.filter { $0.address != person.address })
        }
    }

    private func set(_ list: [MailPerson]) {
        header = list.map(\.header).joined(separator: ", ")
    }
}

/// The people you write with, under the field, lit one first.
private struct MailSuggestions: View {
    let found: [MailDesk.Contact]
    let lit: Int
    let typed: String
    /// The row under the pointer becomes the lit one, as in the field's lists.
    let light: (Int) -> Void
    let take: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(found.enumerated()), id: \.element.id) { index, contact in
                HStack(spacing: 10) {
                    MailAvatar(initials: contact.initials, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        name(contact.said)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        if !contact.name.isEmpty {
                            Text(contact.address).font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(contact.threads == 1 ? "1 thread" : "\(contact.threads) threads")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 10)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(index == lit ? Omnibox.chosenFill : .clear))
                .contentShape(Rectangle())
                .onContinuousHover { if case .active = $0, index != lit { light(index) } }
                .onTapGesture { take(index) }
            }
        }
        .dropFrame(width: 340)
    }

    /// The name, what was typed in it bolder.
    private func name(_ said: String) -> Text {
        let needle = typed.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, let range = said.range(of: needle, options: [.caseInsensitive, .anchored])
            ?? said.range(of: " " + needle, options: .caseInsensitive).map({ said.index(after: $0.lowerBound)..<$0.upperBound }) else { return Text(said) }
        return Text(said[..<range.lowerBound]) + Text(said[range]).fontWeight(.semibold) + Text(said[range.upperBound...])
    }
}

/// A person as a chip: their two letters and their name. Its address under
/// the pointer; a click opens it, to copy it or take the chip away.
private struct MailChip: View {
    let person: MailPerson
    var chosen = false
    @ObservedObject var desk: MailDesk
    var remove: (() -> Void)? = nil
    @State private var open = false
    @State private var copied = false
    @State private var dipped = false
    @MailStill private var still

    private var bad: Bool { !MailDesk.address(person.address) }
    /// Its name, or the name you know the address by, or the address.
    private var said: String {
        guard person.name.isEmpty else { return person.name }
        let known = desk.name(of: person.address)
        return known.isEmpty ? person.address : known
    }

    var body: some View {
        ZStack {
            // What it will say, unseen, holding the chip at its width.
            face.hidden()
            if copied {
                MailCopiedLabel(tint: chosen ? Palette.ground.opacity(0.75) : Palette.muted)
            } else {
                face
            }
        }
        .font(.system(size: 12.5))
        .padding(.leading, 3) // design: the round mark sits close to the chip's curve
        .padding(.trailing, 8)
        .frame(height: 24)
        .background(Capsule().fill(chosen ? Palette.ink : bad ? Color(nsColor: .systemRed).opacity(0.08) : Palette.wash))
        .overlay { if bad { Capsule().strokeBorder(Color(nsColor: .systemRed).opacity(0.5), lineWidth: 1) } }
        .blur(radius: dipped ? 2.5 : 0)
        .scaleEffect(dipped ? 0.96 : 1)
        .opacity(dipped ? 0.45 : 1)
        .contentShape(Capsule())
        .pointerTip(bad ? "Not an address" : person.address)
        .onTapGesture { open = true }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            MailChipCard(person: person, remove: remove.map { take in { open = false; take() } })
        }
        .onChange(of: desk.chipCopied) { _, _ in
            guard desk.chosenChip == person.address else { return }
            dip { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { dip { copied = false } }
        }
    }

    private var face: some View {
        HStack(spacing: 6) {
            MailAvatar(initials: bad ? "!" : MailDesk.initials(said), size: 18, bad: bad)
            Text(said)
                .foregroundStyle(chosen ? Palette.ground : bad ? Color(nsColor: .systemRed) : Palette.ink)
                .lineLimit(1)
        }
    }

    /// Into a blur, the change at its deepest, and out, as a copied value
    /// in the passwords place does (CopyValue).
    private func dip(_ change: @escaping () -> Void) {
        guard !still else { change(); return }
        withAnimation(.easeIn(duration: 0.18)) { dipped = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            change()
            withAnimation(.easeOut(duration: 0.27)) { dipped = false }
        }
    }
}

/// A chip opened: its address, copied by a click, and Remove.
private struct MailChipCard: View {
    let person: MailPerson
    let remove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !person.name.isEmpty {
                Text(person.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
            }
            HStack(spacing: 8) {
                Text("Address").foregroundStyle(Palette.muted)
                Spacer(minLength: 8)
                MailCopy(value: person.address, hangs: true) { Text(person.address).foregroundStyle(Palette.ink).lineLimit(1) }
            }
            .font(.system(size: 12.5))
            .frame(height: 28)
            if let remove {
                Button(action: remove) {
                    HStack {
                        Text("Remove")
                        Spacer()
                        KeyGlyphs(keys: "⌫", size: 11.5, tint: nil, rest: 0.6)
                    }
                    .font(.system(size: 12.5))
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

/// A value that copies itself as the passwords place's do (CopyValue): a
/// plate under the pointer, a click dips it into a blur, it comes out as a
/// gray "Copied" beside two pages on the same plate, never narrower or
/// wider, and two seconds later goes back the same way. The plate stands out past the
/// value's line rather than making it taller, so a line it comes into on
/// hover keeps its height.
private struct MailCopy<Face: View>: View {
    let value: String
    /// On a card's edge (a chip's address): the plate hangs out past the
    /// value, so the value keeps the edge the rows under it keep.
    var hangs = false
    @ViewBuilder let face: () -> Face
    @State private var hovering = false
    @State private var copied = false
    @State private var dipped = false
    @State private var back: DispatchWorkItem?
    @MailStill private var still

    var body: some View {
        Button(action: take) {
            ZStack {
                MailCopiedLabel().hidden()
                face().opacity(copied ? 0 : 1)
                if copied { MailCopiedLabel() }
            }
            .padding(.horizontal, hangs ? 0 : 6)
            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .fill(Omnibox.chosenFill.opacity(copied || hovering ? 1 : 0))
                .padding(.horizontal, hangs ? -6 : 0)
                .padding(.vertical, -2))
            .blur(radius: dipped ? 2.5 : 0)
            .scaleEffect(dipped ? 0.96 : 1)
            .opacity(dipped ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyTip("Copy")
    }

    private func take() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(value, forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        dip { copied = true }
        back?.cancel()
        let work = DispatchWorkItem { dip { copied = false } }
        back = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
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

/// "Copied" beside two pages, gray, as the passwords place says it
/// (CopyValue): the one look of a copy in mail, a value's, Copy All's and
/// a chip's. The mark centered on the words, the words' baseline the
/// label's, so a line aligned on baselines stays put under it.
private struct MailCopiedLabel: View {
    var tint: Color = Palette.muted

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Symbol("doc.on.doc.fill", size: 11)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Self.markDrop }
            Text("Copied")
        }
        .font(.system(size: 12))
        .foregroundStyle(tint)
    }

    /// How far a 12 pt line's baseline sits under its middle.
    private static var markDrop: CGFloat {
        let font = NSFont.systemFont(ofSize: 12)
        return (font.ascender + font.descender) / 2
    }
}

/// What a mail quotes, folded: three dots drawn, not set in type, so their
/// middle is the plate's (the font's bullets sat a point low), the plate
/// darker under the pointer, as a button's.
private struct MailDots: View {
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 3, height: 3) }
        }
        .foregroundStyle(hovering ? Palette.ink : Palette.muted)
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background {
            shape.fill(Palette.wash)
            shape.fill(Palette.ink.opacity(hovering ? 0.06 : 0))
        }
        .contentShape(shape)
        .onHover { hovering = $0 }
    }
}

/// A stack line's plate under the pointer: out past its words, so the name
/// keeps the column's line, a point short of the lines over and under it.
private struct MailRowPlate: View {
    let on: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(on ? Palette.hover : .clear)
            .padding(.horizontal, -8)
            .padding(.vertical, 1)
    }
}

extension View {
    /// A plate under the pointer that hangs out past the words rather than
    /// holding them in: they keep the column's line with it or without it,
    /// and it moves nothing as it comes. Measured from the ink: a mark with
    /// room in its own frame (a Symbol is drawn 1.35 times its size) takes
    /// that room off its side.
    fileprivate func hangingPlate(_ on: Bool, leading: CGFloat = 6, trailing: CGFloat = 6, vertical: CGFloat = 2) -> some View {
        background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
            .fill(on ? Palette.hover : .clear)
            .padding(.leading, -leading) // design: hangs past the ink, each side its own room
            .padding(.trailing, -trailing) // design: hangs past the ink, each side its own room
            .padding(.vertical, -vertical))
    }
}

/// Chips laid a line at a time, onto the next when a line is full.
private struct MailFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = measure(view, last: index == subviews.count - 1)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            var size = measure(view, last: index == subviews.count - 1)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            // The last, the field to type in, takes what the line leaves.
            if index == subviews.count - 1 { size.width = max(size.width, bounds.maxX - x) }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }

    /// The last, the field to type in, asks for no more than room for a name.
    private func measure(_ view: LayoutSubview, last: Bool) -> CGSize {
        last ? view.sizeThatFits(ProposedViewSize(width: 120, height: nil)) : view.sizeThatFits(.unspecified)
    }
}

// MARK: - a new mail

/// A new mail where the list was, as wide as a thread is read.
private struct MailComposeView: View {
    @ObservedObject var desk: MailDesk

    var body: some View {
        ThreadScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    KeyGlyphs(keys: "esc", size: 11.5)
                    Text(desk.splitName)
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .frame(height: 48)
                MailType.newMail()
                    .mailPart("compose:head")
                    .mailFlying("compose:head", desk)
                // Several accounts: which one it goes from, unless its From row says so (MailFromRow).
                if MailCenter.shared.accounts.count > 1, let draft = desk.draft, MailDesk.senders(of: draft).count < 2 {
                    Text("From " + draft.account).font(.system(size: 13)).foregroundStyle(Palette.muted).padding(.top, 4)
                }
                if let draft = desk.draft {
                    // Over a page meanwhile (MailtoCard): drawn as it stands, that one has the keys.
                    MailReply(desk: desk, draft: draft, fresh: true, live: !desk.outside)
                        .mailPart("compose:surface")
                        .mailFlying("compose:surface", desk)
                        .padding(.top, 20)
                }
            }
            .padding(.bottom, FieldFoot.room)
            .mailColumn()
        }
        // Quick Look's controller for a chip of the draft (MailLook).
        .background(MailLookSpot().frame(width: 0, height: 0))
    }
}

/// Who wrote the thread, when there is more to say than their name: the
/// next meeting you share, and other threads with them.
private struct MailPersonRail: View {
    let person: MailDesk.Person
    @State private var editing = false
    @State private var words = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                MailAvatar(initials: MailDesk.initials(person.name.isEmpty ? person.address : person.name), size: 40)
                    .padding(.bottom, 8)
                Text(person.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(person.address).font(.system(size: 12)).foregroundStyle(Palette.muted).textSelection(.enabled)
            }
            // Who they are, from their page in memory (MailPeople): yours to change.
            if editing {
                whoField
            } else if let card = person.card {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Who").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Spacer(minLength: 0)
                        Button("Edit") { words = card.who; editing = true; focused = true }
                            .buttonStyle(.yab(.quiet, .small))
                            .fixedSize()
                    }
                    Text(card.who).font(.system(size: 12.5)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                    Text(card.source).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                }
            }
            if !person.open.isEmpty {
                section("Open between you") {
                    ForEach(Array(person.open.enumerated()), id: \.offset) { _, line in
                        item(line.words, line.when)
                    }
                }
            }
            if let meeting = person.meeting {
                section("Together") {
                    item(meeting.title, meeting.at.formatted(AppDates.dateTime.weekday(.abbreviated).hour().minute()))
                }
            }
            if !person.recent.isEmpty {
                section("Also with them") {
                    ForEach(Array(person.recent.enumerated()), id: \.offset) { _, thread in
                        item(thread.subject, MailPane.said(thread.at))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted)
            rows()
        }
    }

    /// Who, written in place: what you know of them, a few things to add
    /// with a click, Save ⌘↩, Cancel esc.
    private var whoField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who").font(.system(size: 11)).foregroundStyle(Palette.muted)
            TextField("Who they are, how they write", text: $words, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
                .lineLimit(3...8)
                .focused($focused)
            HStack(spacing: 6) {
                ForEach(["Writes casually.", "Numbers in a table."], id: \.self) { more in
                    Button("+ " + more.dropLast()) { words = words.trimmingCharacters(in: .whitespaces) + (words.isEmpty ? "" : " ") + more }
                        .buttonStyle(.yab(.quiet, .small))
                        .fixedSize()
                }
            }
            HStack(spacing: 6) {
                Button {
                    MailDesk.shared.setWho(words, for: person)
                    editing = false
                } label: {
                    HStack(spacing: 6) {
                        Text("Save")
                        KeyGlyphs(keys: "⌘↩", size: 11.5, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.primary, .small))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    editing = false
                } label: {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        KeyGlyphs(keys: "esc", size: 11.5, rest: 0.6)
                    }
                }
                .buttonStyle(.yab(.quiet, .small))
                .keyboardShortcut(.cancelAction)
            }
            .fixedSize()
        }
    }

    private func item(_ title: String, _ when: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink).lineLimit(2)
            Text(when).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
        }
    }
}

// MARK: - a mail's own HTML

/// A mail's HTML in a web view of its own: no script, no store kept, as
/// tall as the mail, the wheel handed to the thread's scroll. A link is a
/// peek over the thread (Browser.peek), with ⌘ a tab of its own.
struct MailBody: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let html: String
    /// The mail it quotes shown (•••); hidden otherwise.
    var quoted = false
    weak var browser: Browser?
    /// The message it is, for the bench; the pictures its words draw by
    /// Content-ID name theirs (MailHTML.pictures, MailCid).
    var message = ""
    /// In a letter made ahead, not yet shown (MailDesk.ahead): nothing of it
    /// from the network until it is, so a sender's pictures never say a
    /// mail was opened when only the one beside it was. Once shown, it
    /// stays as it was shown.
    var unseen = false

    /// The mail's HTML, the part it quotes hidden unless asked for; unseen,
    /// nothing from the network (MailHTML.offline).
    private func shown(_ coordinator: Coordinator) -> String {
        if !unseen { coordinator.seen = true }
        let page = quoted ? html : html + "<style>.gmail_quote,.gmail_attr,blockquote{display:none!important}</style>"
        return coordinator.seen ? page : MailHTML.offline + page
    }
    @State private var height: CGFloat = 40

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MailBodyView {
        let view = MailBodyView.take()
        view.message = message
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.grow = { tall in if abs(tall - height) > 1 { height = tall } }
        context.coordinator.browser = browser
        context.coordinator.message = message
        let shown = shown(context.coordinator)
        context.coordinator.html = shown
        context.coordinator.dark = colorScheme == .dark
        context.coordinator.loading = view.loadHTMLString(shown, baseURL: nil)
        return view
    }

    func updateNSView(_ view: MailBodyView, context: Context) {
        context.coordinator.browser = browser
        context.coordinator.message = message
        view.message = message
        let shown = shown(context.coordinator)
        if context.coordinator.html != shown || context.coordinator.dark != (colorScheme == .dark) {
            context.coordinator.html = shown
            context.coordinator.dark = colorScheme == .dark
            context.coordinator.loading = view.loadHTMLString(shown, baseURL: nil)
        }
    }

    /// The letter let go of it: emptied, and kept for the next one.
    static func dismantleNSView(_ view: MailBodyView, coordinator: Coordinator) {
        coordinator.loading = nil
        MailBodyView.give(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MailBodyView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: height)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var grow: ((CGFloat) -> Void)?
        weak var browser: Browser?
        var html = ""
        var dark = false
        /// The load of this mail's HTML: a web view made earlier may still
        /// finish another's, which says nothing of this one's height.
        var loading: WKNavigation?
        /// Shown once (MailBody.unseen).
        var seen = false
        /// The mail it shows, for its dates' cards.
        var message = ""

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let loading, navigation !== loading { return }
            MainActor.assumeIsolated { MailTime.bodyLoaded = CACurrentMediaTime() }
            // Sender styles often hard-code dark text for a white page. The
            // web view is transparent, so that text disappears in dark Mail.
            // Correct only text with poor contrast against its actual backing;
            // dark text inside a sender's white card stays dark.
            let contrast = """
            (function(){
              if (!window.matchMedia('(prefers-color-scheme: dark)').matches || !document.body) return;
              const cache = new WeakMap();
              const rgb = value => {
                const match = value.match(/^rgba?\\(([^)]+)\\)$/);
                if (!match) return null;
                const parts = match[1].split(/[\\s,\\/]+/).filter(Boolean).map(Number);
                return parts.length >= 3 ? [parts[0], parts[1], parts[2], parts[3] ?? 1] : null;
              };
              const backing = element => {
                if (cache.has(element)) return cache.get(element);
                const parent = element.parentElement;
                const below = parent ? backing(parent) : [28, 28, 28];
                const fill = rgb(getComputedStyle(element).backgroundColor);
                const result = fill ? fill.slice(0, 3).map((v, i) => v * fill[3] + below[i] * (1 - fill[3])) : below;
                cache.set(element, result);
                return result;
              };
              const luminance = color => {
                const c = color.map(v => { v /= 255; return v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4; });
                return .2126 * c[0] + .7152 * c[1] + .0722 * c[2];
              };
              const ratio = (a, b) => {
                const x = luminance(a), y = luminance(b);
                return (Math.max(x, y) + .05) / (Math.min(x, y) + .05);
              };
              for (const element of [document.body, ...document.body.querySelectorAll('*')]) {
                if (![...element.childNodes].some(node => node.nodeType === 3 && node.textContent.trim())) continue;
                const foreground = rgb(getComputedStyle(element).color);
                const background = backing(element);
                if (!foreground || ratio(foreground, background) >= 4.5) continue;
                const light = [237, 237, 237], dark = [23, 23, 23];
                element.style.setProperty('color', ratio(light, background) > ratio(dark, background) ? '#ededed' : '#171717', 'important');
              }
            })();
            """
            // Its own height, measured from nothing, once it has laid out.
            // To the foot of the last thing seen: a paragraph's margin and
            // a hidden pixel after it are no part of the mail.
            let foot = """
            (function(){var b=0;if(!document.body)return 0;document.body.querySelectorAll('*').forEach(function(e){var r=e.getBoundingClientRect();\
            if(r.width>1&&r.height>1&&getComputedStyle(e).visibility!=='hidden'){b=Math.max(b,r.bottom)}});return Math.ceil(b+window.scrollY)})()
            """
            webView.evaluateJavaScript(contrast) { _, _ in
                webView.evaluateJavaScript(foot) { [weak self] value, _ in
                    guard let tall = value as? Double else { return }
                    DispatchQueue.main.async { self?.grow?(CGFloat(tall)) }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return decisionHandler(.allow) }
            decisionHandler(.cancel)
            follow(url, action)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { follow(url, action) }
            return nil
        }

        /// A middle click on a mail's link opens a tab, as a ⌘-click does;
        /// a date's mark, its event's card (MailEvents).
        private func follow(_ url: URL, _ action: WKNavigationAction) {
            MainActor.assumeIsolated {
                if let n = MailDates.index(url) {
                    let id = message
                    if let view = MailBodyView.live.allObjects.first(where: { $0.message == id }) {
                        MailEvents.measure(view, index: n) { MailEvents.shared.open(message: id, index: n, anchor: $0) }
                    } else {
                        MailEvents.shared.open(message: id, index: n)
                    }
                    return
                }
                let middle = Browser.middleClick(action.buttonNumber)
                MailDesk.shared.follow(url, flags: action.modifierFlags.union(middle ? .command : []))
            }
        }
    }
}

/// The mail's web view: the wheel goes on to the thread's scroll, which
/// holds it at its whole height.
///
/// Made ahead and kept (`warm`, `take`, `give`): a web view of a store of
/// its own started a web process of its own at its first load, its fonts
/// registered there, about 10 ms of the main thread for each mail a letter
/// showed. One store in memory serves them all, nothing of it on disk, and
/// a few views wait with their process up and an empty page, so a letter
/// takes one and only loads its mail.
final class MailBodyView: WKWebView {
    /// The message it shows, and every one on screen, for the bench.
    var message = ""
    static let live = NSHashTable<MailBodyView>.weakObjects()

    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

    /// WebKit's Search with Google hands the words to Safari (feedback
    /// #329): here it is the engine picked in Settings, in a tab, as a
    /// mail's link opens.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let item = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierSearchWeb" }) else { return }
        item.title = "Search with \(Engine.name)"
        item.target = self
        item.action = #selector(searchSelection(_:))
    }

    @objc private func searchSelection(_ item: NSMenuItem) {
        let words = PageView.webKitSelection(of: self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let url = Engine.url(for: words) else { return }
        MailDesk.shared.follow(url, flags: [])
    }

    /// What every mail's web view is made with: no script, one store in
    /// memory for all of them, the pictures a mail draws by Content-ID
    /// from the files kept (MailCid). No cookies in it: a sender's picture
    /// can't tell one mail opened from another, as with a store each.
    @MainActor private static let configuration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.websiteDataStore.httpCookieStore.setCookiePolicy(.disallow, completionHandler: nil)
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(MailCid(), forURLScheme: MailHTML.cidScheme)
        // A letter's pictures don't reach this Mac or the network.
        LocalNetwork.protect(config.userContentController)
        return config
    }()

    /// Views ready for a mail, their page empty and their process up.
    @MainActor private static var ready: [MailBodyView] = []
    /// As many as the letter in front and the two made ahead usually show.
    static let kept = 8
    @MainActor private static var warming = false

    /// One for a mail: a ready one, or one made now.
    @MainActor static func take() -> MailBodyView {
        let view = ready.popLast() ?? made()
        live.add(view)
        // The ones taken, made again once the letter is on screen.
        warm()
        return view
    }

    /// One a letter let go of: kept while there is room, its mail emptied a
    /// turn later, not inside the key that let it go (esc lets a letter and
    /// the two made ahead go at once), unless a letter took it meanwhile.
    @MainActor static func give(_ view: MailBodyView) {
        live.remove(view)
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.message = ""
        view.stopLoading()
        guard ready.count < kept else { return }
        ready.append(view)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard ready.contains(view), !live.contains(view) else { return }
                view.loadHTMLString("", baseURL: nil)
            }
        }
    }

    /// Ready ones made up to `kept`, one a turn of the run loop after the
    /// screen in front is drawn: never in the pass a key is handled in.
    @MainActor static func warm() {
        guard !warming, ready.count < kept else { return }
        warming = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                warming = false
                guard ready.count < kept else { return }
                let view = made()
                view.loadHTMLString("", baseURL: nil)
                ready.append(view)
                warm()
            }
        }
    }

    @MainActor private static func made() -> MailBodyView {
        AppleWritingTools.configure(configuration)
        let view = MailBodyView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }
}

/// The new mail a mailto: link opened over a page (Browser.mailto), as
/// mail's page writes one, in the peek's card. How tall it is goes to the
/// peek as the words grow; sent or closed, it stays as it was while the
/// card goes back into the link.
struct MailtoCard: View {
    @ObservedObject var desk: MailDesk
    let tall: (CGFloat) -> Void

    var body: some View {
        if let draft = desk.draft ?? desk.outsideLast {
            MailReply(desk: desk, draft: draft, fresh: true, live: desk.outside && desk.draft != nil, outside: true)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tall($0) }
                // Quick Look's controller for a chip of the draft (MailLook).
                .background(MailLookSpot().frame(width: 0, height: 0))
        }
    }
}

/// A thread over the page, from a row of Now (MailThreadPeek): its mails as
/// mail's page draws them, the last whole and those before it a line each
/// until opened, and under them the row's own Do It, Later and Done. ⌘O
/// goes on with it in mail's page; esc puts it away.
struct MailThreadPeekCard: View {
    let subject: String
    let messages: [MailDesk.Message]
    let actions: [FieldAction]
    weak var browser: Browser?
    let tall: (CGFloat) -> Void
    @State private var unfolded: Set<String> = []
    /// A long thread's middle, folded into one line until asked for, as
    /// mail's page folds it (MailThreadView.entries).
    @State private var earlierOpen = false
    @State private var head: CGFloat = 0
    @State private var words: CGFloat = 0
    @State private var foot: CGFloat = 0

    private func report() { tall(head + words + foot) }

    /// Whose mail it is: the first who wrote but you, or, a thread of yours
    /// alone, whom you wrote to.
    private var sender: String {
        if let first = messages.first(where: { !$0.fromMe }) { return first.from.isEmpty ? first.address : first.from }
        return messages.last.map { "To " + $0.to } ?? "Mail"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(nsImage: MailPage.mark).resizable().frame(width: 14, height: 14)
                    Text(sender + " · Mail").font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
                    Spacer(minLength: 8)
                    Button { browser?.closeThreadPeek() } label: { MailKeyed(words: "Close", keys: "esc") }
                        .buttonStyle(.yab(.quiet)).fixedSize()
                }
                Text(subject.isEmpty ? "(no subject)" : subject)
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(2)
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 10)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { head = $0; report() }
            ThreadScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let folded = messages.count > 4 && !earlierOpen ? messages.count - 3 : 0
                    if folded > 0 {
                        Button { earlierOpen = true } label: {
                            Text("\(folded) earlier").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(Array(messages.enumerated().dropFirst(folded)), id: \.element.id) { n, message in
                        if n == messages.count - 1 || unfolded.contains(message.id) { whole(message) } else { line(message) }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { words = $0; report() }
            }
            HStack(spacing: 8) {
                ForEach(actions) { action in
                    Button {
                        browser?.closeThreadPeek()
                        action.run()
                    } label: {
                        HStack(spacing: 6) {
                            if action.symbol == "agent.face" { Symbol("agent.face", size: 12) }
                            Text(action.title)
                        }
                    }
                    .buttonStyle(.yab(.quiet)).fixedSize()
                }
                Spacer(minLength: 8)
                Button { browser?.keepThreadPeek() } label: { MailKeyed(words: "Open in Mail", keys: "⌘O") }
                    .buttonStyle(.yab(.primary)).fixedSize()
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { foot = $0; report() }
        }
    }

    private func whole(_ message: MailDesk.Message) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MailType.from(message.fromMe ? "You" : message.from, folded: false)
                Spacer(minLength: 8)
                MailType.when(MailPane.said(message.at))
            }
            if let html = message.html {
                MailBody(html: MailHTML.cleaned(html, account: message.account, message: message.id), browser: browser, message: message.id)
            } else {
                Text(message.text)
                    .font(.system(size: 13.5))
                    .lineSpacing(7.5)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func line(_ message: MailDesk.Message) -> some View {
        Button { unfolded.insert(message.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MailType.from(message.fromMe ? "You" : message.from, folded: true)
                Text(message.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.muted).lineLimit(1)
                Spacer(minLength: 8)
                MailType.when(MailPane.said(message.at))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
