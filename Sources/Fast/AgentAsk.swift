import AppKit
import SwiftUI
import UserNotifications

// What an agent asks of you, at the foot of the page it is about.
//
// It used to hang from the tab as a card, over the very page it asked you to
// use: a sign-in's card over the sign-in. Now it is a line where the dock
// is, in the page's own light: the hand, what it needs in a few words, and
// the one or two answers, Done or Send. The page makes room for it, so
// nothing on it is under the line. Whatever is longer opens upward from the
// line: the rest of what it said under ▴, the letter a Send would send, the
// things to pick from.
//
// And when yab isn't the app in front, the Mac says so too, once, and a
// click on that brings you to the tab.

struct AgentPlaque: View {
    @ObservedObject var tab: Tab
    var embedded = false
    /// Its width when it stands in a chat's column, in the field's place:
    /// the whole card's, its frame's inset included, as wide as the field.
    var fitted: CGFloat?
    /// Inside the card's frame.
    private var inner: CGFloat? { fitted.map { $0 - 2 * CardFrame.inset } }
    /// What opens upward: a little short of the line under it.
    private var aboveWidth: CGFloat { inner.map { $0 - 12 } ?? 460 }
    @ObservedObject private var agents = Agents.shared
    @ObservedObject private var confirmation = Keymap.shared.slot(.confirmDanger)
    @State private var open = false
    @State private var other = ""
    @State private var writing = false
    @FocusState private var typing: Bool
    /// ⌥ held: Not now says Never here.
    @State private var option = false
    @State private var watching: Any?
    /// In a column, while the tab it asks in isn't the one in front.
    @State private var away = false

    private var session: Agents.Session? { agents.session(tab.askedBy) }

    var body: some View {
        Group {
            if fitted != nil {
                stacked
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    above
                    line
                }
            }
        }
        .frame(minWidth: inner ?? 300, maxWidth: inner ?? 496, alignment: .leading)
        // In a column, as wide as it is: not the width its words would like.
        .fixedSize(horizontal: fitted == nil, vertical: false)
        // The same frame as every card that asks something: one inset all
        // round, its corner that inset plus a control's.
        .agentCardFrame(surface: !embedded)
        .animation(Motion.arrive, value: open)
        .animation(Motion.arrive, value: writing)
        // The yes rewording to Sending, its button widening round it.
        .animation(Motion.morph, value: tab.sending?.failure)
        .animation(Motion.morph, value: tab.sending == nil)
        .onChange(of: tab.handoff) { _, _ in open = false; writing = false; other = "" }
        .task(id: tab.id) {
            // Only the column can be elsewhere: the page's own foot is on the tab.
            guard fitted != nil, let browser = Agents.front(of: tab) else { return }
            for await front in browser.changes(\.activeID).values {
                let off = front != tab.id
                if away != off { away = off }
            }
        }
        .onAppear {
            watching = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                option = event.modifierFlags.contains(.option)
                return event
            }
        }
        .onDisappear {
            if let watching { NSEvent.removeMonitor(watching) }
            watching = nil
        }
    }

    // MARK: - what opens upward

    @ViewBuilder private var above: some View {
        let permit = tab.permit
        if let ask = FolderAccess.ask(on: tab) {
            // What it is for, and the switch to turn on, always shown: the
            // line alone can't say which of two Yabs it is.
            FolderAskAbove(ask: ask)
                .frame(width: aboveWidth, alignment: .leading)
                .padding(.bottom, CardFrame.inset)
        } else if let permit, !permit.draft.isEmpty {
            // What a Send would send, a few lines of it, all of it under ▴.
            VStack(alignment: .leading, spacing: 4) {
                if !permit.detail.isEmpty {
                    Text(permit.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                drafted(permit.draft)
            }
            .frame(width: aboveWidth, alignment: .leading)
            .padding(.bottom, CardFrame.inset)
        } else if open, let detail = tab.handoffDetail {
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .lineLimit(10)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(width: aboveWidth, alignment: .leading)
                .padding(.bottom, CardFrame.inset)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        if !tab.choices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(tab.choices.enumerated()), id: \.offset) { index, choice in
                    let shortcut = Shortcut.numbered("agentChoice", index + 1)
                    Button { agents.choose(tab, choice) } label: {
                        HStack(spacing: 8) {
                            if let shortcut { ShortcutGlyphs(shortcut, size: 12, tint: Palette.muted) }
                            Text(choice).lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(ChoiceButton())
                }
                if writing {
                    TextField("Something else", text: $other)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.faint, lineWidth: 1))
                        .focused($typing)
                        .onSubmit {
                            let said = other.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !said.isEmpty { agents.choose(tab, said) }
                        }
                        .onAppear { typing = true }
                } else {
                    Button { writing = true } label: {
                        HStack { Text("Something else…").foregroundStyle(Palette.muted); Spacer(minLength: 0) }
                    }
                    .buttonStyle(ChoiceButton())
                }
            }
            .frame(width: aboveWidth, alignment: .leading)
            .padding(.bottom, CardFrame.inset)
        }
    }

    // MARK: - the line

    private var line: some View {
        let permit = tab.permit
        let words = permit?.question ?? tab.handoff ?? ""
        let signing = agents.signingIn(tab)
        return HStack(spacing: 8) {
            if let ask = FolderAccess.ask(on: tab) {
                Symbol(ask.file ? "doc" : "folder", size: 15)
                    .foregroundStyle(Palette.ink)
                    .frame(width: 15, height: 15)
            } else if embedded {
                Color.clear.frame(width: 15, height: 15)
            } else {
                AgentFace(tab: tab, size: 15)
            }
            Text(words)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                // Leave room for the answers in both the dock and the column.
                .pointerTip(words)
            if let permit, permit.draft.isEmpty, !permit.detail.isEmpty {
                Text(permit.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            if canOpen {
                Button { open.toggle() } label: {
                    Symbol("chevron.up", size: 9.5, weight: .semibold)
                        .foregroundStyle(Palette.muted)
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyTip(open ? "Less" : "More")
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if let permit {
                    // A rule can come of the answer: Always here beside the
                    // yes, and ⌥ turns Not now into Never here.
                    if permit.ruleLabel != nil {
                        Button("Always Here") { agents.always(tab) }
                            .buttonStyle(.yab(.quiet, .small))
                            .keyTip("\(permit.ruleLabel ?? "") on \(AgentRules.site(tab.address)) from now on, without asking")
                    }
                    if permit.isFolder {
                        // As drawn: the two ways on, Escape for Not Now;
                        // Stop while it reads again.
                        if permit.answers.isEmpty, let session {
                            Button("Stop") { _ = agents.stop(session.id) }
                                .buttonStyle(.yab(.secondary, .small))
                        }
                    } else if permit.ruleLabel != nil, option {
                        Button { agents.never(tab) } label: { labeled("Never Here", key: "esc") }
                            .buttonStyle(.yab(.secondary, .small))
                    } else {
                        Button { agents.answer(tab, yes: false) } label: { labeled("Not Now", key: "esc") }
                            .buttonStyle(.yab(.secondary, .small))
                    }
                    ForEach(permit.answers, id: \.self) { yes in
                        let last = yes == permit.answers.last
                        Button { agents.answer(tab, yes: true, as: yes.user) } label: { labeled(yes.title, key: last ? (permit.weighty ? confirmation.keys?.text : "⏎") : nil) }
                            .buttonStyle(.yab(last ? .primary : .secondary, .small, glass: last))
                    }
                } else if Agents.optional.contains(tab.id) {
                    // Something it could do without: saying no is Skip, not
                    // stopping the whole task.
                    Button { agents.skip(tab) } label: { labeled("Skip", key: "esc") }
                        .buttonStyle(.yab(.secondary, .small))
                    if away {
                        goThere
                    } else if !signing, tab.choices.isEmpty {
                        Button { agents.handBack(tab) } label: { labeled("Done", key: "⏎") }
                            .buttonStyle(.yab(.primary, .small, glass: true))
                    }
                } else {
                    if let session, session.agent != .external {
                        Button("Stop") { _ = agents.stop(session.id) }
                            .buttonStyle(.yab(.secondary, .small))
                    }
                    if away {
                        goThere
                    } else if !signing, tab.choices.isEmpty {
                        Button { agents.handBack(tab) } label: { labeled("Done", key: "⏎") }
                            .buttonStyle(.yab(.primary, .small, glass: true))
                    }
                }
            }
            .fixedSize()
        }
        .frame(height: ButtonSize.small.height)
    }

    // MARK: - in the chat's field

    /// In the chat's column, in the field's place: the question leads on a
    /// line of its own, then whom and what it goes with, then the words a
    /// yes would send, and the answers at the foot on the right, so the
    /// question is never cut for them. After a yes that sends it stays,
    /// saying Sending, until it has gone (Tab.sending); if it didn't, one
    /// red line says why where the words were, and Try Again takes the yes.
    private var stacked: some View {
        let sending = tab.permit == nil ? tab.sending : nil
        let permit = tab.permit ?? sending?.permit
        let failure = sending?.failure
        let words = permit?.question ?? tab.handoff ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                mark(failed: failure != nil)
                Text(words)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if canOpen, failure == nil {
                    Button { open.toggle() } label: {
                        Symbol("chevron.up", size: 9.5, weight: .semibold)
                            .foregroundStyle(Palette.muted)
                            .rotationEffect(.degrees(open ? 180 : 0))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyTip(open ? "Less" : "More")
                }
            }
            told(permit, failure: failure)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                answers(permit, sending: sending, size: .regular)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
        }
    }

    /// The hand, as the tab wears it while it asks; red once a send failed.
    private func mark(failed: Bool) -> some View {
        Group {
            if let ask = FolderAccess.ask(on: tab) {
                Symbol(ask.file ? "doc" : "folder", size: 15)
                    .foregroundStyle(Palette.ink)
            } else {
                Symbol("hand.raised", size: 15)
                    .foregroundStyle(failed ? ButtonCSS.danger : Color.accentColor)
            }
        }
        .frame(width: 18, height: 18)
    }

    /// Under the question: whom it goes to, every address, and the words
    /// it would send; or, failed, why, where the words were.
    @ViewBuilder private func told(_ permit: AgentPermit?, failure: String?) -> some View {
        if let ask = FolderAccess.ask(on: tab) {
            FolderAskAbove(ask: ask)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        } else if let permit {
            if !permit.detail.isEmpty {
                Text(permit.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(permit.kind == .computer && open ? 10 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
            if let failure {
                Text(failure)
                    .font(.system(size: 12.5))
                    .foregroundStyle(ButtonCSS.danger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .transition(.opacity)
            } else if !permit.draft.isEmpty {
                drafted(permit.draft)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        } else if open, let detail = tab.handoffDetail {
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .lineLimit(10)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }

    /// The answers at the card's foot. Each keeps its place through
    /// Sending and a failure, its words changing in it, so the yes rewords
    /// rather than being replaced.
    @ViewBuilder private func answers(_ permit: AgentPermit?, sending: AgentSending?, size: ButtonSize) -> some View {
        let going = sending != nil && sending?.failure == nil
        let failed = sending?.failure != nil
        if let permit {
            if permit.ruleLabel != nil, sending == nil {
                Button("Always Here") { agents.always(tab) }
                    .buttonStyle(.yab(.quiet, size))
                    .keyTip("\(permit.ruleLabel ?? "") on \(AgentRules.site(tab.address)) from now on, without asking")
            }
            if permit.isFolder {
                if permit.answers.isEmpty, let session {
                    Button("Stop") { _ = agents.stop(session.id) }
                        .buttonStyle(.yab(.secondary, size))
                }
            } else {
                let never = permit.ruleLabel != nil && option && sending == nil
                Button {
                    if failed { agents.dropSending(tab) } else if never { agents.never(tab) } else { agents.answer(tab, yes: false) }
                } label: { labeled(never ? "Never Here" : "Not Now", key: going ? nil : "esc", size: size) }
                    .buttonStyle(.yab(.secondary, size))
                    .disabled(going)
            }
            ForEach(permit.answers, id: \.self) { yes in
                let last = yes == permit.answers.last
                if last || sending == nil {
                    Button {
                        if failed { agents.sendAgain(tab) } else if !going { agents.answer(tab, yes: true, as: yes.user) }
                    } label: {
                        HStack(spacing: 6) {
                            if going { SendingArc() }
                            MorphWords(failed ? "Try Again" : going ? AgentPermit.going(yes.title) : yes.title)
                            if !going, last, failed ? sending?.retry != nil : true,
                               let key = permit.weighty ? confirmation.keys?.text : "⏎", keysReach {
                                KeyGlyphs(keys: key, size: size.wordSize, tint: nil, rest: 0.6)
                                    .transaction { $0.animation = nil }
                            }
                        }
                    }
                    .buttonStyle(.yab(last ? .primary : .secondary, size, glass: last))
                    .allowsHitTesting(!going && (!failed || sending?.retry != nil))
                }
            }
        } else if Agents.optional.contains(tab.id) {
            Button { agents.skip(tab) } label: { labeled("Skip", key: "esc", size: size) }
                .buttonStyle(.yab(.secondary, size))
            if away {
                goThere(size)
            } else if !agents.signingIn(tab), tab.choices.isEmpty {
                Button { agents.handBack(tab) } label: { labeled("Done", key: "⏎", size: size) }
                    .buttonStyle(.yab(.primary, size, glass: true))
            }
        } else {
            if let session, session.agent != .external {
                Button("Stop") { _ = agents.stop(session.id) }
                    .buttonStyle(.yab(.secondary, size))
            }
            if away {
                goThere(size)
            } else if !agents.signingIn(tab), tab.choices.isEmpty {
                Button { agents.handBack(tab) } label: { labeled("Done", key: "⏎", size: size) }
                    .buttonStyle(.yab(.primary, size, glass: true))
            }
        }
    }

    /// In the chat's column, asking for a tab you are not on: Done would
    /// mean nothing from here, so the button is the way there, the site's
    /// mark and name. On the tab it is Done again.
    private var goThere: some View { goThere(.small) }

    private func goThere(_ size: ButtonSize) -> some View {
        let host = ChatComposer.host(tab)
        return Button { agents.bringForward(tab) } label: {
            HStack(spacing: 6) {
                SiteMark(host: host, size: 14, icon: tab.icon)
                Text(Browser.siteName(host))
            }
        }
        .buttonStyle(.yab(.primary, size, glass: true))
        .keyTip("Go to the tab")
    }

    /// A button's words, and its key while that key would reach it, the
    /// way the page's own cards show theirs.
    private func labeled(_ title: String, key: String?, size: ButtonSize = .small) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if let key, keysReach {
                KeyGlyphs(keys: key, size: size.wordSize, tint: nil, rest: 0.6)
                    .transaction { $0.animation = nil }
            }
        }
    }

    /// Return and Escape come to the line from the page, as they come to
    /// the page's own cards: not while the caret is in something typed
    /// into, nor while the field, find or a rename has the keys.
    private var keysReach: Bool {
        guard let browser = agents.browser else { return false }
        // In a chat's field, in the field's place: from the whole window
        // while nothing is typed into (App.take).
        if fitted != nil {
            return browser.active?.typing != true && !browser.fieldShowing && !browser.finding
                && browser.editingTab == nil && !browser.welcoming
        }
        guard browser.active === tab else { return false }
        return !tab.typing && !browser.fieldShowing && !browser.finding && browser.editingTab == nil
            && !browser.welcoming
    }

    /// What a Send would send: three lines of it, all of it under ▴,
    /// scrolled when long, as several mails on one card (sendMails) run.
    @ViewBuilder private func drafted(_ draft: String) -> some View {
        let text = Text(draft)
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.ink)
            .textSelection(.enabled)
        if open {
            // Its own height while it fits, a scroll past that.
            ViewThatFits(in: .vertical) {
                text.fixedSize(horizontal: false, vertical: true)
                ThreadScrollView(.vertical) {
                    text
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 240)
        } else {
            text
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canOpen: Bool {
        if let permit = tab.permit { return permit.draft.count > 160 || (permit.kind == .computer && permit.detail.count > 50) }
        return tab.handoffDetail != nil
    }
}

/// Sending's own turn in the yes, in the button's ink: still with Reduce Motion.
struct SendingArc: View {
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                guard !still else { return }
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turning = true }
            }
    }
}

/// A thing to pick, a row as wide as the plaque, washed under the pointer.
private struct ChoiceButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(configuration.isPressed ? Palette.wash : hovering ? Palette.hover : Palette.ink.opacity(0.03))
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - the way to the tab

extension Agents {
    /// The window's browser that holds the tab.
    static func front(of tab: Tab) -> Browser? {
        BrowserWindows.shared.owner(of: tab.id)?.browser ?? shared.browser
    }

    /// What the last look at a tab's sign-in page said of the ways in this
    /// space is signed in to (SignIns.ways), and the tabs already told.
    static var ways: [UUID: String] = [:]
    static var waysTold: Set<UUID> = []

    /// The sign-in page a request was put up on, by its tab.
    static var signInPage: [UUID: URL] = [:]

    /// A sign-in asked for is done once the tab is back on that site, off
    /// its sign-in pages and settled: nobody needs to say Done for it. A
    /// Google or GitHub page on the way is another site and doesn't count.
    static func signedIn(_ tab: Tab) -> Bool {
        guard tab.handoff != nil, let from = signInPage[tab.id], let now = tab.address, !tab.page.isLoading,
              SignIns.back(from: from, at: now) else { return false }
        signInPage[tab.id] = nil
        return true
    }

    /// The tab that asks, in front of you, its page taking the keys: the
    /// caret lands where the page keeps it (a sign-in's email box).
    func bringForward(_ tab: Tab) {
        let owner = BrowserWindows.shared.owner(of: tab.id)
        guard let browser = owner?.browser ?? self.browser else { return }
        browser.select(tab)
        owner?.window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { tab.page.window?.makeFirstResponder(tab.page) }
    }
}

// MARK: - its keys

extension Agents {
    /// Tabs whose request the task can go on without: it doesn't wait on
    /// them, and they offer Skip where the others offer Stop.
    static var optional: Set<UUID> = []
    /// Such a request's answer, Done ("") or Skip, given after the agent
    /// had gone on: said to it when it asks in that tab again.
    static var answered: [UUID: String] = [:]
    /// Tabs you kept or pinned while they asked something: the agent
    /// waiting there hears they are yours now, not that it was done.
    static var taken: Set<UUID> = []
    /// What a wait answers for such a tab, said the same way by every tool.
    nonisolated static let takenWords = "The user took this tab for themselves before answering; it is theirs now and nothing was done there for you. Carry on without it and don't use that tab again."
    /// What a skipped request answers, so the agent knows it wasn't done.
    nonisolated static let skipped = "\u{0}skipped"

    /// No to something it could do without: the line goes, and the agent,
    /// if it comes back for it, hears it was skipped.
    func skip(_ tab: Tab) {
        tab.chosen = Agents.skipped
        handBack(tab)
    }

    /// Return or Escape from the page, for what is asked at its foot:
    /// Return is the yes an Allow or a sign-in asks for, or Done once you
    /// have done what it needed; ⌘Return the yes for what can't be taken
    /// back, a Send, a Pay, a Delete; Escape is Not now. False when the
    /// line has no answer for that key, so the page keeps it.
    func keyed(_ tab: Tab, event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let escape = event.keyCode == 53 && flags.isEmpty
        let plainReturn = [36, 76].contains(event.keyCode) && flags.isEmpty
        let confirmed = Keymap.shared.matches(event, .confirmDanger)
        // A payment's sheet takes its own keys: Esc cancels, and no key pays.
        if let flow = Payments.shared.flow(tab) {
            let key: PaySheetModel.Key? = escape ? .escape : confirmed ? .confirm : plainReturn ? .enter
                : event.keyCode == 125 && flags.isEmpty ? .down : event.keyCode == 126 && flags.isEmpty ? .up : nil
            guard let key else { return false }
            return flow.key(key) != .ignored
        }
        // A send that didn't go: Try Again on the yes's own keys, Escape
        // Not Now. While it goes the keys are the page's again.
        if tab.permit == nil, let sending = tab.sending, browser?.chatOpen == true {
            guard sending.failure != nil else { return false }
            if escape { dropSending(tab); return true }
            guard sending.retry != nil else { return false }
            if plainReturn {
                browser?.toaster.pop("Try Again with", mark: "hand.raised", keys: Keymap.shared.keys(.confirmDanger)?.caps ?? [])
                return true
            }
            guard confirmed else { return false }
            sendAgain(tab)
            return true
        }
        guard tab.handoff != nil, tab.worker != nil || tab.permit != nil else { return false }
        if let permit = tab.permit {
            if escape { answer(tab, yes: false); return true }
            guard let yes = permit.answers.last else { return false }
            // A bare Return meant for the page doesn't reach it either: it
            // would count as you taking the tab over. The corner says the key.
            if permit.weighty, plainReturn {
                browser?.toaster.pop("\(yes.title) with", mark: "hand.raised", keys: Keymap.shared.keys(.confirmDanger)?.caps ?? [])
                return true
            }
            guard permit.weighty ? confirmed : plainReturn else { return false }
            answer(tab, yes: true, as: yes.user)
            return true
        }
        if escape, Agents.optional.contains(tab.id) { skip(tab); return true }
        guard plainReturn, tab.choices.isEmpty, !signingIn(tab) else { return false }
        handBack(tab)
        return true
    }
}

// MARK: - the page makes room

extension Agents {
    /// The foot of the page kept clear while something is asked there, so
    /// the line covers nothing on it. One change when it comes, one when it
    /// goes.
    static func makeRoom(_ tab: Tab, _ room: Bool) {
        // TODO(chromium): carry obscured page insets through PageHandle.
        // PageFoot runs this even without an agent question or a built page.
        guard #available(macOS 26.0, *) else { return }
        guard tab.engineKind == .webKit else { WebKitOnly.note("Obscured page insets", engine: tab.engineKind); return }
        guard let web = tab.webKitOnly("Obscured page insets", build: false) else { return }
        // The line, its card's inset above and below, and the air it
        // keeps off the page's edge.
        let bottom: CGFloat = room ? ButtonSize.small.height + 2 * CardFrame.inset + 14 : 0
        guard web.obscuredContentInsets.bottom != bottom else { return }
        var insets = web.obscuredContentInsets
        insets.bottom = bottom
        web.obscuredContentInsets = insets
    }
}

// MARK: - the Mac says so

@MainActor
final class AgentNotices: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotices()
    weak var browser: Browser?

    /// The question's cause, rather than its shortened display line. A
    /// folder recheck changes its phase, not what the person was asked.
    enum Cause: Equatable {
        case handoff(session: String?, reason: String, detail: String?, choices: [String], optional: Bool)
        case permit(AgentPermit)

        static func of(_ permit: AgentPermit) -> Cause {
            guard case .folder(var ask) = permit.kind else { return .permit(permit) }
            ask.stage = .closed
            ask.sent = false
            ask.checked = .distantPast
            ask.error = ""
            var stable = AgentPermit(kind: .folder(ask), session: permit.session, detail: permit.detail)
            stable.draft = permit.draft
            stable.amount = permit.amount
            stable.pays = permit.pays
            stable.forSession = permit.forSession
            return .permit(stable)
        }
    }

    struct Hand: Equatable {
        let id: String
        let cause: Cause
        let askOrder = DispatchTime.now().uptimeNanoseconds
        static func == (left: Hand, right: Hand) -> Bool { left.id == right.id && left.cause == right.cause }
    }
    private final class Member {
        weak var tab: Tab?
        init(_ tab: Tab) { self.tab = tab }
    }
    private var members: [String: [UUID: Member]] = [:]
    private struct Posting {
        var content: UNMutableNotificationContent
        let quiet: Bool
        let inFront: Bool
    }
    private var posting: [String: Posting] = [:]
    private var chatPosts: [String: UUID] = [:]

    var testActive: Bool?
    private var active: Bool { Store.testing ? (testActive ?? NSApp.isActive) : NSApp.isActive }
    private(set) var handReceipts: [[String: String]] = []
    private func receipt(_ event: String, _ id: String) {
        if Store.testing { handReceipts.append(["event": event, "id": id]) }
    }
    /// A clock seam: tests capture the work item and advance exactly to
    /// three minutes, without making production reminders run sooner.
    var scheduleReminder: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func handState() -> [String: Any] {
        ["held": Array(held.keys).sorted(), "pending": Array(posting.keys).sorted(),
         "reminders": Array(reminders.keys).sorted(), "receipts": handReceipts,
         "delivering": held.values.map(\.delivery).sorted()]
    }

    /// The only arrival path for every tab hand writer. A copied window
    /// has the original cause and notice, not a new permission request.
    func changed(_ tab: Tab) {
        let inherited = tab.takeInheritedHandoff()
        if tab.handoffSuperseded {
            // A retained old callback can resolve only the question it
            // transferred; a late phase rewrite cannot reclaim the tab.
            if tab.handoff == nil, let old = tab.supersededHandoffNotice { finish(old) }
            tab.handoffNotice = nil
            return
        }
        guard !tab.gone else { clear(tab); tab.handoffNotice = nil; return }
        let explicit = tab.nextHandoffCause
        tab.nextHandoffCause = nil
        guard let words = tab.handoff else {
            if let hand = tab.handoffNotice { finish(hand) }
            tab.handoffNotice = nil
            return
        }
        let display = Cause.handoff(session: tab.askedBy, reason: words, detail: tab.handoffDetail,
                                    choices: tab.choices, optional: Agents.optional.contains(tab.id))
        let sameDisplay = tab.handoffDisplayCause == display
        tab.handoffDisplayCause = display
        let cause = tab.permit.map(Cause.of) ?? explicit ?? display
        let samePlainAsk = explicit == nil && tab.permit == nil && sameDisplay && tab.handoffNotice != nil
        let hand = inherited ?? (tab.handoffNotice?.cause == cause || samePlainAsk ? tab.handoffNotice : nil)
            ?? Hand(id: "agent." + tab.id.uuidString + "." + UUID().uuidString, cause: cause)
        if let old = tab.handoffNotice, old != hand { finish(old, except: tab) }
        tab.handoffNotice = hand
        // Work deliberately out of sight still asks nobody.
        if Agents.shared.session(tab.askedBy)?.sealed != true { Agents.notify(tab, words) }
    }

    /// Only from the app itself: a bare binary has no notifications.
    static var possible: Bool {
        Bundle.main.bundlePath.hasSuffix(".app") && Bundle.main.bundleIdentifier != nil
    }

    /// The Mac's answers come here from the start, so a click that opens
    /// Yab still reaches what it was for: a mail's buttons (MailNotify).
    static func listen() {
        guard possible else { return }
        UNUserNotificationCenter.current().delegate = shared
        // A question from Yab's last run waits on nothing now: its
        // notification goes, so the Mac shows no question nobody asks.
        let center = UNUserNotificationCenter.current()
        Task {
            let stale = await center.deliveredNotifications().filter {
                let info = $0.request.content.userInfo
                return info["tab"] != nil || info["permit"] != nil
            }.map(\.request.identifier)
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    /// Every button any of Yab's notifications wears, mail's and sites':
    /// setting them replaces the app's whole set.
    static func prepareCategories() {
        guard possible else { return }
        UNUserNotificationCenter.current().setNotificationCategories(
            MailNotifySystem.categories.union(SiteNotices.categories).union(permitCategories))
    }

    // MARK: the chat's question

    /// A chat's question's buttons: the yes in its own word, and Not Now.
    /// Neither brings Yab forward: the answer is given where it is read.
    /// Only what can be taken back gets them (AgentPermit.Place.chat);
    /// money, words sent as you and the Mac are answered in Yab.
    nonisolated static let permitYes = "agent.permit.yes"
    nonisolated static let permitNo = "agent.permit.no"

    /// A permit's category: another app's agent's mail question says its
    /// yes is for the session.
    nonisolated static func permitCategory(_ permit: AgentPermit) -> String? {
        permit.kind == .mailRead && permit.forSession ? "agent.mail.read.session" : permitCategory(permit.kind)
    }

    nonisolated static func permitCategory(_ kind: AgentPermit.Kind) -> String? {
        switch kind {
        case .mailRead: return "agent.mail.read"
        case .mailSite: return "agent.mail.site"
        case .mailChange: return "agent.mail.change"
        default: return nil
        }
    }

    nonisolated static var permitCategories: Set<UNNotificationCategory> {
        let no = UNNotificationAction(identifier: permitNo, title: "Not Now", options: [])
        return Set([("agent.mail.read", "Search"), ("agent.mail.read.session", "Allow for This Session"),
                    ("agent.mail.site", "Go"), ("agent.mail.change", "Allow")].map { id, yes in
            UNNotificationCategory(identifier: id, actions: [UNNotificationAction(identifier: permitYes, title: yes, options: []), no],
                                   intentIdentifiers: [], options: [])
        })
    }

    /// A chat's question as the Mac says it, kept here in a test world
    /// instead (Store.testing), never on screen.
    struct Asked: Equatable {
        let id: String
        let category: String
        let title: String
        let subtitle: String
        let body: String
        let info: [String: String]
        var quiet = false
    }
    private(set) var asked: [Asked] = []
    private(set) var cleared: [String] = []
    /// What macOS allows a test world: whatever the test says. Unasked
    /// turns allowed when asked, as a yes to macOS's question would.
    var testPermission = MailNotify.Permission.allowed
    /// How often a test world's chat questions asked macOS's leave.
    private(set) var permissionAsks = 0
    /// The last question's notification on its way, for a test to wait on.
    private(set) var asking: Task<Void, Never>?

    /// A chat's question said by the Mac, with Yab in front too, since no
    /// tab says it: its buttons answer it there (Agents.answer(chat:)), a
    /// click opens the chat with the question in its field. `said` hears
    /// whether the Mac could say it; it can't without the person's leave,
    /// from a bare binary, or with nobody at Yab. Never asked before, macOS
    /// asks for that leave now, since a question waits on it; turned down
    /// once, it isn't asked again.
    func ask(_ permit: AgentPermit, chat root: Agents.Session, said: @escaping @MainActor (Bool) -> Void) {
        guard let category = Self.permitCategory(permit) else { said(false); return }
        let id = "agent.permit.\(root.id)"
        let title = "\(root.planName) needs you"
        let subtitle = [root.title ?? root.name, root.askedOnce].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        let body = [permit.question, permit.detail].filter { !$0.isEmpty }.joined(separator: "\n")
        let info = ["permit": permit.key, "chat": root.id]
        let post = UUID()
        chatPosts[id] = post
        if Store.testing {
            if testPermission == .unasked { permissionAsks += 1; testPermission = .allowed }
            let allowed = testPermission == .allowed
            if allowed { asked.append(Asked(id: id, category: category, title: title, subtitle: subtitle, body: body, info: info)) }
            asking = Task { @MainActor in
                guard self.chatPosts[id] == post, root.permit == permit else { return }
                said(allowed)
            }
            return
        }
        guard Self.possible, !Headless.hidden else { said(false); return }
        UNUserNotificationCenter.current().delegate = self
        let browser = self.browser ?? Agents.shared.browser
        // Its home in sight: the column out with this chat.
        let seen = NSApp.isActive && browser.map { $0.chatOpen && $0.chatShown == root.id } == true
        asking = Task { @MainActor in
            let system = MailNotifySystem()
            let permission = await system.permission()
            guard self.chatPosts[id] == post, root.permit == permit else { return }
            if permission == .unasked { await system.ask() }
            let allowed = await system.permission() == .allowed
            guard self.chatPosts[id] == post, root.permit == permit else { return }
            guard allowed else {
                // The corner still says it, and its sound with it.
                self.hold(id, nil, quiet: seen)
                said(false)
                return
            }
            Self.prepareCategories()
            self.hold(id, Self.question(title: title, subtitle: subtitle, body: body, thread: root.id,
                                        category: category, info: info), quiet: seen)
            said(true)
        }
    }

    // MARK: questions waiting

    /// A question's notification: its own sound, Time Sensitive (it breaks
    /// through a Focus once Yab's profile carries the entitlement, and is
    /// an ordinary one until then), one group a chat.
    static func question(title: String, subtitle: String = "", body: String, thread: String,
                         category: String? = nil, info: [String: String]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        // Sound for questions off: the banner comes quiet.
        content.sound = !AskSound.on ? nil : (!Store.testing) && AskSound.ready() ? UNNotificationSound(named: UNNotificationSoundName(rawValue: AskSound.name)) : .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = thread
        if let category { content.categoryIdentifier = category }
        content.userInfo = info
        return content
    }

    /// The questions waiting, by notification id: what the Mac says of
    /// each once Yab isn't in front, and whether it has.
    private struct Held {
        var content: UNMutableNotificationContent?
        let delivery: String
        var said = false
    }
    private var held: [String: Held] = [:]
    /// Any question waiting on the person.
    var waiting: Bool { !held.isEmpty }
    private var reminders: [String: DispatchWorkItem] = [:]
    private var attention: Int?
    private var watchingApp: [NSObjectProtocol] = []
    /// How long a question waits before the Mac says it once more.
    static let remindAfter: TimeInterval = 180

    /// A question come: with Yab in front the window says it (its corner,
    /// its column, the page's foot) with a sound unless you are looking at
    /// it already; with Yab behind the Mac says it at once, the Dock's icon
    /// bouncing until you come. Once more after three minutes unanswered.
    func hold(_ id: String, _ content: UNMutableNotificationContent?, quiet: Bool, inFront: Bool = false) {
        if held[id] != nil {
            held[id]?.content = content
            receipt("duplicate", id)
            return
        }
        held[id] = Held(content: content, delivery: id + "." + UUID().uuidString)
        receipt("hold", id)
        if !Store.testing { AskPresence.shared.watch(true); watchApp() }
        if active, !inFront {
            if !quiet {
                receipt("sound", id)
                AskSound.play(for: id)
            }
        } else {
            say(id)
        }
        let remind = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.remind(id) } }
        reminders[id] = remind
        receipt("scheduled", id)
        scheduleReminder(Self.remindAfter, remind)
    }

    /// The Mac says it, or again: the one said before goes first, so the
    /// new one is a banner of its own and not a quiet update.
    private func say(_ id: String, again: Bool = false) {
        guard var item = held[id] else { return }
        item.said = true
        held[id] = item
        if attention == nil {
            receipt("bounce", id)
            attention = Store.testing ? 0 : NSApp.requestUserAttention(.criticalRequest)
        }
        guard let base = item.content, let content = base.mutableCopy() as? UNMutableNotificationContent else {
            // Permission denied: the corner still calls, audibly too.
            receipt("sound", id)
            AskSound.play(for: id)
            return
        }
        receipt(again ? "reminder" : "say", id)
        if again { content.subtitle = [content.subtitle, "Waiting 3 min"].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ") }
        // Heard in the window already: the banner comes quiet. Only the
        // three-minute reminder rings again.
        if !again, AskSound.heard(id) { content.sound = nil }
        AskSound.said(id)
        if Store.testing {
            asked.append(Asked(id: item.delivery, category: content.categoryIdentifier, title: content.title,
                               subtitle: content.subtitle, body: content.body,
                               info: content.userInfo as? [String: String] ?? [:], quiet: content.sound == nil))
            return
        }
        let center = UNUserNotificationCenter.current()
        let delivery = item.delivery
        if again { center.removeDeliveredNotifications(withIdentifiers: [delivery]) }
        let request = UNNotificationRequest(identifier: delivery, content: content, trigger: nil)
        Task { @MainActor in
            try? await center.add(request)
            // add may finish after an answer or replacement removed it.
            if self.held[id]?.delivery != delivery {
                center.removeDeliveredNotifications(withIdentifiers: [delivery])
                center.removePendingNotificationRequests(withIdentifiers: [delivery])
            }
        }
    }

    private func remind(_ id: String) {
        reminders[id] = nil
        guard held[id] != nil, !active else { return }
        say(id, again: true)
    }

    /// Yab going behind other apps with questions still waiting: the Mac
    /// says the ones only the window said. Coming back, the bouncing stops.
    private func watchApp() {
        guard watchingApp.isEmpty else { return }
        let center = NotificationCenter.default
        watchingApp = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wentBehind() }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attention = nil }
            },
        ]
    }

    func wentBehind() {
        for (id, item) in held where !item.said { say(id) }
    }

    /// A question answered or gone, wherever: nothing more is said of it.
    private func release(_ id: String) {
        let item = held.removeValue(forKey: id)
        posting[id] = nil
        reminders.removeValue(forKey: id)?.cancel()
        AskSound.forget(id)
        receipt("clear", id)
        if Store.testing { cleared.append(id) }
        if (!Store.testing), Self.possible {
            let ids = [id] + (item.map { [$0.delivery] } ?? [])
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
        guard held.isEmpty else { return }
        if !Store.testing { AskPresence.shared.watch(false) }
        if let attention, !Store.testing { NSApp.cancelUserAttentionRequest(attention) }
        attention = nil
    }

    /// The chat's question answered or gone: its notification goes too.
    func clear(chat id: String) {
        let key = "agent.permit.\(id)"
        chatPosts[key] = nil
        release(key)
    }

    /// A press on a chat's question's notification: its buttons answer it,
    /// a click on the notification opens the chat with the question in its
    /// field, and putting it away answers nothing.
    static func answer(_ action: String, chat: String, key: String) {
        switch action {
        case permitYes: Agents.shared.answer(chat: chat, yes: true, key: key)
        case permitNo: Agents.shared.answer(chat: chat, yes: false, key: key)
        case UNNotificationDefaultActionIdentifier:
            AssistantApprovals.shared.seen(.chat(chat), key: key)
            shared.show(chat: chat)
        default: break
        }
    }

    /// Mail sends have request identities, not tab notification identities.
    /// The banner only opens Yab; sending is still approved on the full card.
    func mailAnswered(_ id: String) { release("agent.mailAsk." + id) }

    func mailAsked(_ id: String, _ permit: AgentPermit) {
        let root = Agents.shared.session(permit.session)
        let content = Self.possible || Store.testing
            ? Self.question(title: "\(root?.planName ?? "An agent") needs you", body: permit.question,
                            thread: permit.session, info: ["mailAsk": id]) : nil
        hold("agent.mailAsk." + id, content, quiet: NSApp.isActive)
    }

    /// A click on a chat's question: Yab in front, the question's card on
    /// screen. Yab's own chat comes out in the column, the card in its
    /// field, beside a page or an empty window alike; another app's
    /// agent's, with no chat of Yab's to stand in, waits in the window's
    /// corner, where Return and Escape answer it (Agents.cornerKeyed).
    func show(chat: String) {
        guard let browser = come(holding: nil) else { return }
        if Agents.shared.columnHolds(chat) { browser.showChat(chat) }
    }

    /// An agent that needs you, or is done, said by the Mac while Yab is
    /// behind other apps. Never asked for here: only where macOS lets Yab
    /// say things already; otherwise Settings › AI › Agents says they are
    /// off and offers Allow…, as Settings › Mail does (MailNotify).
    /// `inFront`: said by the Mac with Yab in front too.
    func post(_ tab: Tab, title: String, body: String, inFront: Bool = false) {
        guard Self.possible || Store.testing, !tab.gone, !tab.handoffSuperseded,
              let hand = tab.handoffNotice else { return }
        let id = hand.id
        members[id, default: [:]][tab.id] = Member(tab)
        let quiet = active && Agents.front(of: tab)?.activeID == tab.id
        let thread = tab.askedBy.flatMap { Agents.shared.root(of: $0) } ?? tab.id.uuidString
        let content = Self.question(title: title, body: body, thread: thread,
                                    info: ["tab": tab.id.uuidString, "hand": id])
        if held[id] != nil {
            // A phase update or a child window continues the same ask.
            // In particular, it must not re-arm its three-minute timer.
            if held[id]?.content != nil { held[id]?.content = content }
            receipt("duplicate", id)
            return
        }
        if posting[id] != nil { posting[id]?.content = content; receipt("duplicate", id); return }
        posting[id] = Posting(content: content, quiet: quiet, inFront: inFront)
        receipt("post", id)
        if Store.testing {
            let pending = posting.removeValue(forKey: id)!
            hold(id, testPermission == .allowed ? pending.content : nil, quiet: pending.quiet, inFront: pending.inFront && !pending.quiet)
            return
        }
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            let allowed: Bool
            allowed = await MailNotifySystem().permission() == .allowed
            guard let pending = self.posting.removeValue(forKey: id), self.members[id]?.isEmpty == false else { return }
            let family = self.members[id]?.values.compactMap(\.tab) ?? []
            let quietNow = self.active && family.contains { !$0.gone && Agents.front(of: $0)?.activeID == $0.id }
            self.hold(id, allowed ? pending.content : nil, quiet: quietNow, inFront: pending.inFront && !quietNow)
        }
    }

    /// A task done: a click opens its chat, where its answer is.
    func post(chat session: String, title: String, body: String) {
        post(id: session, info: ["chat": session], title: title, body: body)
    }

    /// A watched page's condition holding (PageWatches): said with Yab in
    /// front too, since nothing on screen says it; a click opens the page.
    func post(watch id: String, url: String, title: String, body: String) {
        post(id: "watch.\(id)", info: ["page": url], title: title, body: body, inFront: true)
    }

    private func post(id: String, info: [String: String], title: String, body: String, inFront: Bool = false) {
        guard Self.possible, inFront || !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            guard await MailNotifySystem().permission() == .allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = info
            try? await center.add(UNNotificationRequest(identifier: "agent.\(id)", content: content, trigger: nil))
        }
    }

    /// Resolving or replacing a question resolves the sign-in windows
    /// which copied it too. Closing just one page instead detaches it.
    private func finish(_ hand: Hand, except kept: Tab? = nil) {
        let family = members.removeValue(forKey: hand.id)?.values.compactMap(\.tab) ?? []
        release(hand.id)
        for tab in family where tab !== kept && tab.handoffNotice == hand {
            tab.handoffNotice = nil
            Agents.optional.remove(tab.id)
            tab.handoff = nil
        }
    }

    func clear(_ tab: Tab) {
        guard let hand = tab.handoffNotice, var family = members[hand.id] else { return }
        // A same-id replacement may already own the slot. Closing the old
        // WebKit object must not detach its replacement.
        guard family[tab.id]?.tab === tab else { return }
        family[tab.id] = nil
        family = family.filter { $0.value.tab != nil }
        if family.isEmpty {
            members[hand.id] = nil
            release(hand.id)
        } else { members[hand.id] = family }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        nonisolated(unsafe) let info = response.notification.request.content.userInfo
        await respond(response.actionIdentifier, info)
    }

    /// A press on one of Yab's notifications, by its action and what it
    /// carries: from the Mac, or from a test world's bench (agent-notice-click).
    nonisolated func respond(_ action: String, _ info: [AnyHashable: Any]) async {
        nonisolated(unsafe) let info = info
        if let mail = info["mailAsk"] as? String {
            guard action == UNNotificationDefaultActionIdentifier else { return }
            await MainActor.run {
                guard Agents.shared.mailRequest(mail) != nil else { return }
                AssistantApprovals.shared.seen(.mail(mail))
                _ = self.come(holding: nil)
            }
            return
        }
        if let hand = info["hand"] as? String {
            guard action == UNNotificationDefaultActionIdentifier else { return }
            await MainActor.run {
                if let tab = self.members[hand]?.values.compactMap(\.tab).first(where: { !$0.gone }) {
                    AssistantApprovals.shared.seen(on: tab)
                    self.open(tab.id.uuidString)
                }
            }
            return
        }
        if let key = info["permit"] as? String, let chat = info["chat"] as? String {
            await MainActor.run { Self.answer(action, chat: chat, key: key) }
            return
        }
        if info["site"] != nil {
            await MainActor.run { SiteNotices.answer(action, info) }
            return
        }
        if let account = info["mail"] as? String {
            guard let act = MailNotify.Act(action: action) else { return }
            await MailNotify.shared.answer(act, account: account, threads: info["threads"] as? [String] ?? [], message: info["codeMessage"] as? String)
            return
        }
        // A question from another Mac's agent: Yab in front shows its card.
        if info["approval"] != nil {
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                SyncCenter.shared.takeForeignAssistantApprovals()
            }
            return
        }
        if let page = info["page"] as? String {
            await MainActor.run {
                let browser = self.open(nil) ?? self.browser
                if let url = URL(string: page) { browser?.arrive(url) }
            }
            return
        }
        if let chat = info["chat"] as? String {
            await MainActor.run {
                let browser = self.open(nil) ?? self.browser
                browser?.showChat(chat)
            }
            return
        }
        let id = info["tab"] as? String
        await MainActor.run {
            if action == UNNotificationDefaultActionIdentifier, let uuid = id.flatMap(UUID.init(uuidString:)) {
                if let tab = (self.browser ?? Agents.shared.browser)?.everyTab.first(where: { $0.id == uuid }) {
                    AssistantApprovals.shared.seen(on: tab)
                } else { AssistantApprovals.shared.seen(.tab(uuid)) }
            }
            self.open(id)
        }
    }

    /// A click on an agent's notification: the tab that asked, in front.
    /// A send or a chat's question asked on a tab of yours stands in the
    /// window's corner wherever you are: Yab in front is enough, and
    /// you stay on the page and in the space you were in.
    @discardableResult
    func open(_ id: String?) -> Browser? {
        let uuid = id.flatMap(UUID.init(uuidString:))
        let browser = come(holding: uuid)
        guard let uuid else { return browser }
        if let tab = browser?.everyTab.first(where: { $0.id == uuid }), Agents.inCorner(tab) || Agents.sendingInCorner(tab) {
            return browser
        }
        // In whichever window and space it waits now (BrowserWindows.reveal).
        return BrowserWindows.shared.reveal(uuid)?.browser ?? browser
    }

    /// Yab in front with a window of it on screen, ready for what was
    /// clicked: shown if it was hidden, the window that holds `tab` (else
    /// the one last in front) out of the Dock and key, a new one if none
    /// is open. Its browser, the one the question is read in.
    @discardableResult
    func come(holding tab: UUID?) -> Browser? {
        // Hidden for agents: the browser now, on the tab that asked,
        // with no welcome over it.
        if Headless.hidden {
            Headless.show(.request)
            Links.showBrowser()
        }
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        let windows = BrowserWindows.shared
        let holder = tab.flatMap { id in windows.browsers.first { $0.everyTab.contains { $0.id == id } } }
        let browser = holder ?? windows.activeBrowser ?? windows.browsers.first ?? self.browser ?? Agents.shared.browser
        if let browser, let window = windows.window(for: browser) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            Links.showBrowser(browser)
        }
        return browser
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.content.userInfo["mail"] != nil { return await MailNotify.shared.presenting() }
        if notification.request.content.userInfo["site"] != nil {
            nonisolated(unsafe) let info = notification.request.content.userInfo
            return await MainActor.run { SiteNotices.presenting(info) }
        }
        return [.banner, .sound]
    }
}

extension Agents {
    /// A request, said by the Mac when yab isn't in front, and with yab in
    /// front too for an agent the user runs in a terminal (Claude Code,
    /// Codex): they are looking at its chat, not at the tab that asks.
    static func notify(_ tab: Tab, _ line: String) {
        let asker = shared.session(tab.askedBy)
        let name = asker?.name ?? "An agent"
        AgentNotices.shared.browser = shared.browser
        AgentNotices.shared.post(tab, title: "\(name) needs you", body: line, inFront: asker?.cli == "external")
    }
}
