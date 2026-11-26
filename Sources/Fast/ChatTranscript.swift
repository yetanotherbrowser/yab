import AppKit
import SwiftUI
import SyncKit

// A chat's turns as Messages shows a conversation: your words on the
// accent at the right, the agent's in grey at the left, its answer a
// message a paragraph, a table between them on a card of its own. The
// agent says briefly what it will do, works behind the typing bubble,
// then answers. Completed tools fold into a row below the answer;
// their activity stays hidden while it works. Questions and permissions
// still use their own cards.
// The dots pulse on Core Animation layers without per-frame SwiftUI work.

struct ChatTranscript: View {
    let browser: Browser
    let chat: Chat
    let live: Bool
    /// Scrolled away from the top: the head's face shrinks.
    @Binding var away: Bool
    /// How tall the field stands over the turns' foot, with what stands
    /// over it (ChatColumn): the turns scroll on under it.
    var foot: CGFloat = 0
    /// When the turns last came into view, landing at their foot.
    @State private var shown = Date()
    private static let end = "end"
    /// Scrolled to the very end, the spare under the last line in view.
    @State private var atEnd = true
    /// The scroll view's height, the field's foot in it.
    @State private var height: CGFloat = 0
    /// Kept to the turns' foot as they grow. Off once you scroll up to read,
    /// and while a finished answer too long for the room stands at its start.
    @State private var follow = true
    /// A finished answer stood at its start (hold), since when.
    @State private var holding: Date?
    /// The last turn just ended, when: an answer written out after it may still
    /// outgrow the room, and is held at its start then.
    @State private var ended: Date?
    /// The last turn's own height, before its room: over the room, it doesn't fit.
    @State private var lastHeight: CGFloat = 0
    /// Words came in under you while you were up reading.
    @State private var below = false
    /// The last words have gone down under the field, not just the empty
    /// room and spare under them: only then is there more below.
    @State private var hidden = false
    /// How far the turns have gone under the head (ColumnEnds).
    @State private var ends = ColumnEnds()
    /// All the turns drawn, not only the last few: a long chat comes into
    /// view with its newest turns, the ones in sight at its foot, and the
    /// rest come in over them a turn later, up the scroll where they
    /// aren't seen, so the chat is there on the frame it is asked for.
    @State private var whole = false
    /// The turns drawn on a chat's first frame.
    static let first = 6
    /// Where the turns dim and blur: down to a fall above the name's glass
    /// as it stands scrolled (the face small, the name up), so they come
    /// clear at the glass's foot and only what goes under it is veiled.
    private static let under: CGFloat = ChatHead.height - ChatHead.bottom - ChatHead.lift - ColumnEnds.fall
    @Environment(\.accessibilityReduceMotion) private var still
    @Environment(\.accessibilityReduceTransparency) private var clear
    /// The way down's drop of glass.
    static let drop: CGFloat = 38

    /// Liquid Glass round the way down, on the accent when new words came
    /// under you; the material where there is none.
    @ViewBuilder
    static func glass(new: Bool, plain: Bool) -> some View {
        if #available(macOS 26.0, *), !plain, PullView.glassy {
            Color.clear.glassEffect(new ? Glass.regular.tint(Color.accentColor.opacity(0.7)).interactive() : Glass.regular.interactive(), in: Circle())
        } else {
            Circle().fill(.regularMaterial)
                .overlay(Circle().fill(Color.accentColor.opacity(new ? 0.85 : 0)))
        }
    }

    /// Where the scroll stands: how far its end is under the view, how tall
    /// it all is, and how tall the scroll itself.
    private struct Place: Equatable {
        var gap: CGFloat
        var content: CGFloat
        var room: CGFloat
    }

    /// What shows between the head and the field.
    private var visible: CGFloat { max(0, height - ChatHead.height - ChatHead.contentGap - foot) }
    /// Left empty under the last line, always: a third of what shows, so
    /// the newest words stand well over the field, never on it.
    private var spare: CGFloat { max(16, (visible / 3).rounded()) }
    /// The last turn is never shorter than what shows over the spare: sent,
    /// your words stand under the head and the answer grows into the room
    /// under them, the turns standing still. 4 over the turns, 24 the gap before the end.
    private var room: CGFloat { max(0, visible - 4 - 24 - spare) }

    var body: some View {
        // Queued words wait over the field: only a send follows them down.
        let sent = Agents.shared.session(chat.id)?.sends ?? 0
        ScrollViewReader { reader in
            ThreadScrollView(.vertical) {
                VStack(spacing: 0) {
                    // Not lazy: a lazy stack guesses the height of turns it has
                    // not drawn, and each new guess moved the scroll, the turns
                    // jumping to the top while you typed under them. A chat is
                    // turns by the dozen, not the thousand.
                    VStack(alignment: .leading, spacing: 24) {
                        let turns = chat.turns
                        let session = Agents.shared.session(chat.id)
                        let cut = browser.chatEditing.flatMap { edit in
                            edit.chat == chat.id ? turns.firstIndex { $0.contains { $0.id == edit.item } } : nil
                        }
                        // Your words sent and not yet heard back: they stand at
                        // once, where the words from the field land (SendFlight),
                        // not a second or two later when the agent says them back.
                        // Words queued for after it (the last of `saying`) wait
                        // in their rows over the field, not here.
                        let waiting = Array((session?.saying ?? []).dropLast(session?.queue.count ?? 0))
                        // Words into the turn going on stand under it; a message
                        // of its own begins a turn of its own, "Starting".
                        let steering = live && (session?.steering ?? 0) > 0 && !turns.isEmpty
                        let pending = session != nil && live && !steering && (turns.isEmpty || !waiting.isEmpty)
                        // Each page its agent published: one card, in the turn of its newest version (ArtifactCard.placement).
                        let placed = ArtifactPages.on ? ArtifactCard.placement(turns) : [:]
                        // The pending message occupies the very same row and view
                        // as its provider echo. A separate ChatPending discarded
                        // the sent bubble and typing indicator at acknowledgement.
                        let displayed = pending ? turns + [[ChatItem(id: "pending", kind: .asked,
                            detail: (session?.carrying.first ?? []).joined(separator: "\n"),
                            text: waiting.first ?? session?.asked.first ?? chat.title, state: .done, began: Date())]] : turns
                        // Each keeps its place's id when those before it come in.
                        ForEach(Array(displayed.enumerated()).dropFirst(whole ? 0 : max(0, displayed.count - Self.first)), id: \.offset) { index, turn in
                            let last = index == displayed.count - 1
                            VStack(alignment: .leading, spacing: 24) {
                                // When, as Messages says it: over a turn that came a while after the one before.
                                if let at = ChatStamp.at(displayed, index) {
                                    Text(ChatStamp.words(at))
                                        .font(.system(size: 11))
                                        .foregroundStyle(Palette.muted)
                                        .frame(maxWidth: .infinity)
                                        .padding(.bottom, -14) // design: 10 over its turn, as Messages has it
                                }
                                ChatTurn(browser: browser, chat: chat, turn: turn, working: live && last && (pending || waiting.isEmpty || steering), last: last,
                                         ending: ChatItem.stopped(in: turn) ? "stopped" : last ? chat.state : "done", fallback: last ? chat.answer : "",
                                         notebook: chat.knowing == true && index == 0, cards: placed[index] ?? [])
                                    // A turn over and done is drawn again only when
                                    // something of its own changes, not for each word
                                    // the newest one gets.
                                    .equatable()
                                if last, !pending { BoostLearningView(chat: chat, live: live).padding(.leading, MessageBubble.words) }
                                if last, steering {
                                    ForEach(Array(waiting.enumerated()), id: \.offset) { _, words in
                                        HStack { Spacer(minLength: 48); SentWords(words, bubble: true) }
                                    }
                                }
                            }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { now in
                                if last { lastHeight = now }
                            }
                            // Each turn's top: the one first when earlier turns were asked for stays in place.
                            .background(alignment: .top) {
                            }
                            // The foot of the last words, before the room under them.
                            .background(alignment: .bottom) {
                                if last {
                                    let field = height - foot
                                    Color.clear.frame(height: 1)
                                        .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).minY > field } action: { hidden = $0 }
                                }
                            }
                            // The room for its answer: the last turn's only.
                            .frame(minHeight: last ? room : nil, alignment: .top)
                            // A message of yours being edited: it and what came after fade, to go.
                            .opacity(cut.map { index >= $0 } == true ? 0.4 : 1)
                            .animation(still ? nil : Motion.chatQuick, value: cut)
                        }
                    }
                    .padding(.horizontal, ChatLook.turnsInset)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity)
                    .frame(maxWidth: .infinity)
                    // The top of the turns: once it has gone up under the head,
                    // the head's face shrinks. Told only as it comes and goes,
                    // not for each point scrolled.
                    .background(alignment: .top) {
                        Color.clear.frame(height: 1)
                            .onScrollVisibilityChange(threshold: 0.01) { top in scrolled(!top) }
                    }
                    // Under the last line, the field and the spare: scrolled to
                    // the very end, the words still stand clear of the field.
                    Color.clear.frame(height: 24 + foot + spare).id(Self.end)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Kept to its foot when anything changes size while it follows:
            // the field growing a row, an answer growing, the column dragged
            // wider. Up reading, or held at an answer's start, the turns stay
            // where they are as more comes under them.
            .defaultScrollAnchor(follow ? .bottom : .top, for: .sizeChanges)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Room under the head, which the turns scroll up beneath.
            .contentMargins(.top, ChatHead.height + ChatHead.contentGap, for: .scrollContent)
            .contentMargins(.top, ChatHead.height, for: .scrollIndicators)
            .contentMargins(.bottom, foot, for: .scrollIndicators)
            // Going up under the head the turns show through a little,
            // dimmed and blurred, and come clear a little past it, as the
            // tabs' column has its rows (ColumnFade, ColumnBlur): the
            // column's own glass shows, not a veil of white or black.
            .modifier(OwnScrollEdges())
            .modifier(ColumnScrolled(ends: ends))
            .mask { ColumnFade(ends: ends, top: Self.under, foot: false) }
            .overlay { ColumnBlur(ends: ends, top: Self.under, foot: false, grain: 0) }
            .frame(maxHeight: .infinity)
            // You, not the turns, tell where the scroll is: the end going down
            // out of view with nothing grown is your hand going up; back at
            // the end, it follows again. The turns growing keep it as it was.
            .onScrollGeometryChange(for: Place.self) { geo in
                Place(gap: max(0, geo.contentSize.height + geo.contentInsets.bottom - geo.visibleRect.maxY), content: geo.contentSize.height,
                      room: geo.containerSize.height)
            } action: { old, now in
                atEnd = now.gap <= 8
                let settled = holding.map { Date().timeIntervalSince($0) > 0.5 } ?? true
                if atEnd, settled {
                    follow = true
                    holding = nil
                    below = false
                // The scroll itself made another size (its hosting view laid
                // out first at none, then the column's) is not the hand.
                } else if now.gap > old.gap + 0.5, abs(now.content - old.content) < 0.5, abs(now.room - old.room) < 0.5 {
                    follow = false
                }
            }
            // Words you would read, not steps kept out of sight, came in
            // while you were up reading: the way down says so.
            .onChange(of: Self.words(chat)) { _, _ in
                if !follow, holding == nil, !atEnd { below = true }
            }
            .overlay(alignment: .bottom) {
                if !follow, hidden {
                    Button {
                        follow = true
                        holding = nil
                        below = false
                        withAnimation(still ? nil : Motion.chatIn) { reader.scrollTo(Self.end, anchor: .bottom) }
                    } label: {
                        // A drop of glass and its arrow, no words; new words
                        // under you tint it with the accent.
                        Symbol("arrow.down", size: 15, weight: .semibold)
                            .foregroundStyle(below ? Color.white : Palette.ink)
                            .frame(width: Self.drop, height: Self.drop)
                            .background { Self.glass(new: below, plain: clear) }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .keyTip(below ? "New Below" : "More Below")
                    .accessibilityLabel(below ? "New below" : "More below")
                    // Close over the field, on its veil.
                    .padding(.bottom, foot + 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
                }
            }
            .animation(still ? nil : Motion.chatQuick, value: !follow && hidden)
            .onAppear {
                shown = Date()
                opened(reader)
                // Kept at the foot as they come, in the same update: the
                // scroll otherwise keeps its place from the top, the rest
                // pushing the newest words down out of sight.
                if !whole {
                    DispatchQueue.main.async {
                        whole = true
                        if follow { reader.scrollTo(Self.end, anchor: .bottom) }
                    }
                }
            }
            .onChange(of: chat.id) { _, _ in
                shown = Date()
                opened(reader)
            }
            // The newest words in view as they come: a jump, no scrolling motion.
            .onChange(of: chat.items.last?.text.count) { _, _ in
                if follow, live, !atEnd { reader.scrollTo(Self.end, anchor: .bottom) }
            }
            .onChange(of: chat.items.count) { _, _ in
                if follow { reader.scrollTo(Self.end, anchor: .bottom) }
            }
            // Your words sent: back at the foot, the turns going up on the
            // flight's own curve as your words fly into their line.
            .onChange(of: sent) { old, now in
                guard now > old else { return }
                follow = true
                holding = nil
                below = false
                withAnimation(still ? nil : Motion.chatIn) { reader.scrollTo(Self.end, anchor: .bottom) }
            }
            // Done: an answer too long for the room stands at its start, to be
            // read down from there, not from its end. Written out after, it
            // may outgrow the room a moment later: held then.
            .onChange(of: live) { was, now in
                guard was, !now else { return }
                ended = Date()
                if lastHeight > room + 1 { hold(reader) }
            }
            .onChange(of: lastHeight) { _, now in
                guard !live, let ended, Date().timeIntervalSince(ended) < 3, now > room + 1 else { return }
                hold(reader)
            }
            // The field grew a row, or gave one back: the last words stay over it.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { now in
                height = now
                if follow { reader.scrollTo(Self.end, anchor: .bottom) }
            }
        }
    }

    /// The last turn's finished answer at its start, under the head. Not a
    /// failure: its card, with Try Again, stays where it shows at the end.
    private func hold(_ reader: ScrollViewProxy) {
        guard follow, holding == nil, chat.state != "failed", let id = Self.answerStart(chat) else { return }
        follow = false
        holding = Date()
        withAnimation(still ? nil : Motion.chatIn) { reader.scrollTo(id, anchor: .top) }
    }

    /// A chat come into view: at its end, always, its newest words over
    /// the field; what came before is up the scroll.
    private func opened(_ reader: ScrollViewProxy) {
        follow = true
        holding = nil
        ended = nil
        below = false
        reader.scrollTo(Self.end, anchor: .bottom)
    }

    /// What there is to read: messages, your words and your picks, and how
    /// far the newest has been written. Steps out of sight don't count.
    private static func words(_ chat: Chat) -> [Int] {
        [chat.items.filter { [.message, .asked, .chose].contains($0.kind) }.count, chat.items.last?.text.count ?? 0]
    }

    /// The scroll's mark at the start of an item's words (ChatTurn).
    static func mark(_ id: String) -> String { "start." + id }
    /// Where the last turn's answer begins. Its answer is drawn as one text
    /// under its last shown message's id (ChatTurn.answer, Chat.visibleMessage).
    static func answerStart(_ chat: Chat) -> String? {
        chat.turns.last?.last {
            $0.kind == .message && $0.name != Agents.handedOver && $0.name != ChatItem.compacted
                && Chat.visibleMessage($0, failed: chat.state == "failed", failure: chat.answer)
        }.map { mark($0.id) }
    }

    /// A chat that opens at its foot starts with the small face, at once;
    /// scrolled by hand, the face shrinks and grows on the column's curve.
    private func scrolled(_ now: Bool) {
        guard away != now else { return }
        if Date().timeIntervalSince(shown) < 0.8 {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { away = now }
        } else {
            away = now
        }
    }
}

/// One turn: what you asked, the agent's opening words, and its answer.
/// While it works, only the typing bubble appears below its words.
private struct ChatTurn: View, Equatable {
    let browser: Browser
    let chat: Chat
    let turn: [ChatItem]
    let working: Bool
    let last: Bool
    /// How the chat stood when this turn was its last: done, stopped, failed.
    let ending: String
    /// The session's answer, for a turn whose message never came as a step.
    let fallback: String
    /// Get to Know's run: its answer leads to its notebook (KnowCard,
    /// KnowPage.linked) and isn't one to ask again or repeat.
    let notebook: Bool
    /// Since when a press has been held for your yes.
    @State private var heldSince: Date?
    /// Its answer still being written out (WriteOut).
    @State private var writingOut = false
    @State private var renderedWords: Set<String> = []
    @State private var openAnswerURL: OpenURLAction
    @Environment(\.accessibilityReduceMotion) private var still

    /// The pages its agent published whose card stands in this turn
    /// (ArtifactCard.placement): none once a later turn has a newer version.
    var cards: [ArtifactRef] = []

    /// What the turn draws from: its own items and the few things of its
    /// chat it shows (its tabs, subagents, agent, start, its cards).
    static func == (a: ChatTurn, b: ChatTurn) -> Bool {
        a.turn == b.turn && a.working == b.working && a.last == b.last && a.ending == b.ending
            && a.fallback == b.fallback && a.notebook == b.notebook && a.browser === b.browser
            && a.chat.id == b.chat.id && a.chat.cli == b.chat.cli && a.chat.started == b.chat.started
            && a.chat.tabs == b.chat.tabs && a.chat.subagents == b.chat.subagents && a.cards == b.cards
    }

    init(browser: Browser, chat: Chat, turn: [ChatItem], working: Bool, last: Bool, ending: String, fallback: String, notebook: Bool = false,
         cards: [ArtifactRef] = []) {
        self.cards = cards
        self.browser = browser
        self.chat = chat
        self.turn = turn
        self.working = working
        self.last = last
        self.ending = ending
        self.fallback = fallback
        self.notebook = notebook
        _openAnswerURL = State(initialValue: OpenURLAction { url in
            if KnowPage.isKnow(url) {
                KnowPage.show(in: browser, section: url.fragment)
                return .handled
            }
            return MailChat.follow(url, in: browser) ? .handled : .systemAction
        })
    }

    private var asked: ChatItem? { turn.first { $0.kind == .asked && $0.name != "steer" } ?? turn.first { $0.kind == .asked } }
    /// What you added while it worked.
    private var steered: [ChatItem] { turn.filter { $0.kind == .asked && $0.name == "steer" && $0.id != asked?.id } }
    private var messages: [ChatItem] {
        turn.filter { Self.said($0) && Chat.visibleMessage($0, failed: last && ending == "failed", failure: fallback) }
    }
    /// Words of the agent's own, not yab's line on who carried on, nor a
    /// line of the chat's own (ChatItem.notes, Yab's asides, a divider).
    private static func said(_ item: ChatItem) -> Bool {
        item.kind == .message && item.name != Agents.handedOver && !item.isNote && !item.isAside && item.name != ChatItem.compacted
            && !item.isQuiet
    }
    /// A subagent's report the agent was handed: the turn opens on its card.
    private var report: SubagentReport? { asked?.subagentReport }
    /// The session's answer, but never for a report's turn: a quiet one
    /// has no words, and the answer before it isn't said again.
    private var fallen: String { report == nil ? fallback : "" }
    /// yab's line where the agent ran out of room and the other carried on.
    private var handover: ChatItem? { turn.last { $0.kind == .message && $0.name == Agents.handedOver } }
    private var steps: [ChatItem] {
        turn.filter { [.tool, .command, .edit, .subagent].contains($0.kind) && !StepWords.of($0).quiet }
    }
    /// A turn you stopped, said in a quiet line of its own: its steps never are.
    private var stoppedWords: String {
        Chat.worked(turn).map { "You stopped after " + Chat.span($0) } ?? "You stopped it"
    }
    /// A press of its held for your yes, in a tab of this chat's.
    private var held: Bool {
        working && browser.everyTab.contains { tab in tab.permit.map { Agents.shared.root(of: $0.session) == chat.id } ?? false }
    }
    /// What it waits on you for, and since when.
    private var wait: ChatWait? {
        guard working else { return nil }
        if let asking = turn.last(where: { $0.state == .running && StepWords.of($0).asks }) {
            return ChatWait(words: StepWords.of(asking), since: asking.began ?? Date(), step: asking.id)
        }
        return held ? ChatWait(words: nil, since: heldSince ?? Date()) : nil
    }
    /// The answer, once it is over: all it wrote after its last step, as
    /// one; what it said before that is the work's, folded with it.
    private var answer: ChatItem? {
        guard !working, !ChatItem.stopped(in: turn), var last = messages.last else { return nil }
        let work = turn.lastIndex { ![.message, .thinking, .asked, .card].contains($0.kind) } ?? -1
        let visible = Set(messages.map(\.id))
        let after = turn.enumerated().filter { $0.offset > work && visible.contains($0.element.id) }.map(\.element)
        // A turn that ends on a widget: its words before it stay above it,
        // in the turn, never moved under it as an answer.
        if after.isEmpty, let drawn = turn.lastIndex(where: { $0.kind == .widget }),
           let said = turn.lastIndex(where: { $0.id == last.id }), said < drawn { return nil }
        if after.count > 1 { last.text = after.map(\.text).joined(separator: "\n\n") }
        return last
    }
    /// The messages that make the answer, kept out of the work.
    private var answered: Set<String> {
        guard answer != nil else { return [] }
        let work = turn.lastIndex { ![.message, .thinking, .asked, .card].contains($0.kind) } ?? -1
        return Set(turn.enumerated().filter { $0.offset > work && Self.said($0.element) }.map(\.element.id))
    }
    /// Where the answer begins in the turn, once there is one.
    private var answerAt: Int? {
        let ids = answered
        return ids.isEmpty ? nil : turn.firstIndex { ids.contains($0.id) }
    }
    /// The chat's own lines that came after the answer began: under it.
    private var trailing: [ChatItem] {
        guard let from = answerAt else { return [] }
        return turn.enumerated().filter { $0.offset > from && $0.element.isNote }.map(\.element)
    }
    /// What it said on its way, what you added and what you picked when
    /// it asked, its thoughts and the chat's own lines (ChatItem.notes), in
    /// the order they came; never the answer.
    private var along: [ChatItem] {
        let kept = Set(steered.map(\.id))
        let failed = !working && last && ending == "failed"
        let done = answered
        let from = done.isEmpty ? nil : turn.firstIndex { done.contains($0.id) }
        let shown = answer?.id, written = writing?.id
        return turn.enumerated().filter { pair in
            let (offset, item) = (pair.offset, pair.element)
            // Yab's quiet lines; an error that ended the last turn is its failure card's.
            if item.isAside { return !item.text.isEmpty && !(failed && item.name == "error") }
            if item.isNote || item.isThought { return from.map { offset < $0 } ?? true }
            if item.kind == .chose { return !item.text.isEmpty }
            if item.kind == .widget { return true }
            if item.kind == .message, item.name == ChatItem.compacted { return true }
            if kept.contains(item.id) { return true }
            return Self.said(item) && !item.text.isEmpty && item.id != shown && !done.contains(item.id) && item.id != written
        }.map(\.element)
    }
    /// The answer as it is being written: the last message, while nothing follows it.
    private var writing: ChatItem? {
        guard working, let last = turn.last, Self.said(last), !last.text.isEmpty, last.name != ChatItem.question else { return nil }
        return last
    }

    /// A card waits for the actual text view, including its last ink fade.
    /// Starting empty avoids a flash before the first child preference arrives.
    private var cardsReady: Bool {
        guard !working else { return false }
        let failed = last && ending == "failed"
        let text = answer.map { notebook ? KnowPage.linked($0.text) : $0.text }
            ?? (messages.isEmpty && !failed ? fallen : "")
        return text.isEmpty || renderedWords.contains(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let report, let asked {
                ChatSubagentCard(name: report.name, report: report)
                    .padding(.leading, MessageBubble.tailRoom) // design: on the bubbles' body, as the chat's plates stand
                    .background(alignment: .top) { Color.clear.frame(height: 1).id(ChatTranscript.mark(asked.id)) }
            } else if let asked {
                ChatBubble(browser: browser, item: asked,
                           editIn: notebook || asked.isInternalContinuation ? nil : chat.id)
                    .background(alignment: .top) { Color.clear.frame(height: 1).id(ChatTranscript.mark(asked.id)) }
            }
            if working || !messages.isEmpty || !steps.isEmpty || !fallen.isEmpty || ending == "stopped"
                || turn.contains(where: { $0.kind == .widget || $0.isNote || $0.isThought }) {
                if let handover {
                    Text(handover.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .padding(.leading, MessageBubble.words)
                }
                // What it said on its way, what you added and what you
                // picked when it asked, in the order they came: messages,
                // as Messages shows them. Its steps are never among them.
                let along = along
                ForEach(along.indices, id: \.self) { index in
                    let item = along[index]
                    if item.isAside {
                        ChatAside(item: item, agent: AgentModels.agentName(chat.cli))
                    } else if item.isNote {
                        ChatNote(item: item)
                    } else if item.isThought {
                        // Thoughts in a row, one fold: "Thought for 34s".
                        if index == 0 || !along[index - 1].isThought {
                            ChatThought(items: Array(along[index...].prefix { $0.isThought }))
                        }
                    } else if item.kind == .message, item.name == ChatItem.compacted {
                        ChatCompacted()
                    } else if item.kind == .message {
                        // The tail only on the last of its run: the next
                        // message, or the answer after it, carries it on.
                        let next = index + 1 < along.count ? Self.said(along[index + 1]) : (writing ?? answer) != nil
                        ChatWords(text: item.text, streaming: false, bubbles: true, tail: !next)
                            .contextMenu { Button("Copy") { ChatCopy.put(item.text) } }
                            .padding(.bottom, next ? -2 : 0) // design: its messages in a run 4 apart, as within one answer
                    } else if item.kind == .widget {
                        // Drawn where it was made, between its words.
                        ChatWidget(browser: browser, item: item)
                            .padding(.vertical, 4) // design: a widget stands 10 from the words round it, as a table does
                    } else {
                        ChatBubble(browser: browser, item: item)
                    }
                }
                // Its subagents at work, each its own card, till each reports.
                if working, last { ChatSubagentsLive(chat: chat) }
                // Waiting on you it says nothing more: its question stands
                // in the turns, its choices or its yes over the field.
                if working, writing == nil, wait == nil {
                    ChatTyping()
                        .transition(still ? .identity : ChatArrival.typing)
                }
                let failed = !working && last && ending == "failed"
                // The turn says why already, a status or an error of its own.
                let told = turn.last { !$0.isThought }.map { $0.isNote && ["status", "error", "notice"].contains($0.name) } ?? false
                // The answer being written and the answer done are one text,
                // never drawn anew as it ends.
                if let shown = writing ?? answer {
                    // Come just now, often in one lump as the turn ends: written out.
                    let arriving = last && Date().timeIntervalSince(shown.began ?? .distantPast) < 3
                    // The typing capsule itself grows into its first message.
                    let grow = arriving && !still && ChatWords.opensSaid(shown.text)
                    let words = ChatWords(text: writing == nil && notebook ? KnowPage.linked(shown.text) : shown.text, streaming: writing != nil,
                                          partial: writing != nil && shown.state == .running,
                                          fresh: arriving, bubbles: true, grow: grow)
                        // What you can do with it once it is all written out, in its menu.
                        .modifier(ChatAnswerMenu(browser: browser, chat: chat, asked: notebook || report != nil ? nil : asked?.text, answer: shown,
                                                 on: writing == nil && !writingOut && !failed))
                        // Where a finished answer is read from (ChatTranscript.answerStart).
                        .background(alignment: .top) { Color.clear.frame(height: 1).id(ChatTranscript.mark(shown.id)) }
                        .padding(.bottom, 2) // design: what follows the answer stands 8 under it, a bubble or a card last
                    // The handler and view identity stay the same when a
                    // streamed answer first acquires an internal mail link.
                    words
                        .environment(\.openURL, openAnswerURL)
                        .onPreferenceChange(ChatWords.Rendered.self) { renderedWords = $0 }
                        .transition(still || !arriving || grow ? .identity : ChatArrival.message)
                } else if writing == nil, !working, !failed, messages.isEmpty, !fallen.isEmpty {
                    ChatWords(text: fallen, streaming: false, bubbles: true)
                        .padding(.bottom, 2) // design: what follows the answer stands 8 under it
                        .onPreferenceChange(ChatWords.Rendered.self) { renderedWords = $0 }
                }
                // What its tools made, a card each, under the answer
                // (ChatResultCard); with nothing said, out of the capsule.
                let carded = turn.filter { $0.kind == .card }
                if !working, !carded.isEmpty {
                    ChatResultCards(browser: browser, items: carded, grow: messages.isEmpty && fallen.isEmpty)
                        .padding(.leading, MessageBubble.tailRoom)
                        .modifier(ChatCardReveal(ready: cardsReady))
                }
                // The chat's own lines after the answer: you stopped it, a
                // background task done, out of room.
                ForEach(trailing) { ChatNote(item: $0) }
                if !working, ending == "stopped" {
                    Text(stoppedWords)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .padding(.leading, MessageBubble.words)
                }
                // Pictures its steps took or looked at (a screenshot, an
                // image it read), small, in the order they came: right under
                // the answer, over the line of what it did.
                let pictures = turn.flatMap(ChatItem.pictures).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                if !working, !pictures.isEmpty {
                    ThreadScrollView(.horizontal) {
                        let shown = Array(pictures.suffix(8))
                        HStack(spacing: 6) { ForEach(shown, id: \.self) { ChatThumb(path: $0, group: shown) } }
                    }
                    .background { ChatQuickLookAnchorView() }
                    .scrollIndicators(.never)
                    .padding(.leading, MessageBubble.tailRoom)
                    .modifier(ChatCardReveal(ready: cardsReady))
                }
                // Files it made for you (a page saved, a download): a card
                // each, as Grok's file under its answer (ChatFileCard).
                let made = ChatItem.files(in: turn)
                if !working, !made.isEmpty {
                    ChatFileCards(paths: made)
                        .padding(.leading, MessageBubble.tailRoom)
                        .modifier(ChatCardReveal(ready: cardsReady))
                }
                // What it put on the clipboard, in words, and Copy Again.
                if !working, let copied = ChatItem.copied(in: turn) {
                    ChatCopiedLine(what: copied.what, clip: copied.clip)
                        .padding(.leading, MessageBubble.tailRoom)
                        .modifier(ChatCardReveal(ready: cardsReady))
                }
                // A page it published (the Artifact tool): its card, under
                // the answer once its words have settled; one card an
                // artifact, in the turn of its newest version.
                if ArtifactPages.on {
                    ForEach(cards, id: \.key) { ref in
                        ArtifactCard(browser: browser, chat: chat.id, ref: ref)
                            .transition(still ? .identity : .opacity)
                            .modifier(ChatCardReveal(ready: cardsReady))
                    }
                }
                if writing == nil, let answer {
                    // Under the answer once it is all written out.
                    if cardsReady {
                        if notebook, !failed { KnowCard(browser: browser).padding(.horizontal, MessageBubble.tailRoom) }
                        // A boost it made and Yab put on your page: the
                        // page before and after, as Yab checked it.
                        if !failed, last, turn.contains(where: { $0.kind == .tool && $0.name == "boost" }) {
                            ChatBoostPictures(chat: chat.id)
                                .padding(.leading, MessageBubble.tailRoom)
                                .transition(.opacity)
                        }
                    }
                }
                if failed, !told {
                    // Again with what went with it: Try Again had sent the words alone.
                    let sent = asked.flatMap { Agents.shared.session(chat.id)?.sent[$0.id] } ?? []
                    ChatFailure(browser: browser, chat: chat, raw: fallback, agent: AgentModels.agentName(chat.cli), sent: sent,
                                retry: asked.map { asked in { Agents.shared.followUp(chat.id, asked.text, with: sent) } },
                                without: asked.map { asked in { item in Agents.shared.followUp(chat.id, asked.text, with: sent.filter { $0 != item }) } })
                        .padding(.leading, MessageBubble.words)
                }
            }
        }
        .onChange(of: held, initial: true) { _, now in heldSince = now ? (heldSince ?? Date()) : nil }
        .onPreferenceChange(ChatWords.WritingOut.self) { writingOut = $0 }
        // The answer replaces the typing bubble; its actions follow once written out.
        .animation(still ? nil : Motion.chatQuick, value: writing == nil)
        .animation(still ? nil : Motion.chatQuick, value: (writing ?? answer)?.id)
        .animation(still ? nil : Motion.chatQuick, value: working)
        .animation(still ? nil : Motion.chatQuick, value: writingOut)
    }
}

/// Lay out results once, then reveal them in place after the words above.
private struct ChatCardReveal: ViewModifier {
    let ready: Bool
    @Environment(\.accessibilityReduceMotion) private var still

    func body(content: Content) -> some View {
        content
            .compositingGroup()
            // Keep hosted AppKit icons laid out while visually hidden.
            // A fully culled layer can reappear at the host's origin.
            .opacity(ready ? 1 : 0.0001)
            .disabled(!ready)
            .allowsHitTesting(ready)
            .accessibilityHidden(!ready)
            .animation(still ? nil : .easeOut(duration: 0.22), value: ready)
    }
}

/// Where the agent's context was compacted: a thin line across the chat,
/// never words of its own.
private struct ChatCompacted: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            Text("Context compacted")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize()
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One of Yab's quiet lines between the agent's words (ChatItem.asides):
/// the conversation compacted, as a thin divider; a notice, a review's
/// start and end, an error, as a muted line.
private struct ChatAside: View {
    let item: ChatItem
    let agent: String

    var body: some View {
        if item.name == "compacted" {
            HStack(spacing: 8) {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                Text("Context compacted").fixedSize()
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .padding(.vertical, 6)
            .padding(.leading, MessageBubble.words)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Context compacted")
        } else {
            Text(item.name == "error" ? Chat.failure(item.text, agent: agent) : item.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, MessageBubble.words)
        }
    }
}

/// A new message grows from the corner beside the typing bubble. Its
/// removal is immediate: opening words can move into the kept transcript
/// as a tool starts, without a second copy lingering over them. The
/// typing bubble goes at once too: the answer's own bubble grows out of
/// its place (ChatWords.grow), and anything else just stands there.
private enum ChatArrival {
    static let message = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.96, anchor: .bottomLeading))
            .animation(.spring(response: 0.3, dampingFraction: 0.86)),
        removal: .identity)
    static let typing = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .bottomLeading)).animation(Motion.chatIn),
        removal: .identity)
}

/// The agent between messages: three dots in a Messages-style bubble.
struct ChatTyping: View {
    var body: some View {
        ChatTypingDots()
            .frame(width: 32, height: 8)
            .frame(width: 64, height: 36) // design: compact typing capsule with room around its three dots
            .background {
                Capsule().fill(Palette.ink)
                    .overlay(alignment: .bottomLeading) {
                        Circle().fill(Palette.ink)
                            .frame(width: 10, height: 10)
                            .offset(x: 2, y: 2)
                        Circle().fill(Palette.ink)
                            .frame(width: 4, height: 4)
                            .offset(x: -2, y: 6) // design: the two round marks of the typing bubble's tail
                    }
                    .compositingGroup()
                    .opacity(0.07)
            }
            .padding(.leading, MessageBubble.tailRoom)
            .padding(.bottom, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Agent is thinking")
    }
}

/// The typing capsule growing into the answer's first bubble, drawn in
/// that bubble's place: the bubble is laid out at its own size at once,
/// and only this drawing moves, from the capsule's 64 by 36 at its top
/// corner to the whole frame (Motion.reshape), the corner min(18, h/2) all
/// the way, the fill the capsule's. The tail stays at the foot's corner:
/// the capsule's round marks go as the bubble's hook comes, with the dots,
/// in the first 0.1 s.
struct ChatGrowth: View {
    let grown: Bool
    let dotsOut: Bool
    let tail: Bool

    static let capsule = CGSize(width: 64, height: 36) // design: ChatTyping's capsule

    var body: some View {
        let progress: CGFloat = grown ? 1 : 0
        ZStack(alignment: .topLeading) {
            ZStack {
                Grown(progress: progress, part: .body).fill(Palette.ink)
                if tail { Grown(progress: progress, part: .hook).fill(Palette.ink).opacity(dotsOut ? 1 : 0) }
                Grown(progress: progress, part: .marks).fill(Palette.ink).opacity(dotsOut ? 0 : 1)
            }
            .compositingGroup()
            .opacity(0.07)
            ChatTypingDots()
                .frame(width: 32, height: 8)
                .frame(width: Self.capsule.width, height: Self.capsule.height)
                .opacity(dotsOut ? 0 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private struct Grown: Shape {
        var progress: CGFloat
        enum Part { case body, hook, marks }
        let part: Part

        var animatableData: CGFloat {
            get { progress }
            set { progress = newValue }
        }

        func path(in rect: CGRect) -> Path {
            let from = ChatGrowth.capsule
            let frame = CGRect(x: rect.minX, y: rect.minY, width: from.width + (rect.width - from.width) * progress,
                               height: from.height + (rect.height - from.height) * progress)
            switch part {
            case .body: return MessageBubble(mine: false, tail: false).path(in: frame)
            case .hook: return MessageBubble(mine: false, tail: true).path(in: frame)
            case .marks:
                // ChatTyping's two round marks, at the foot's corner.
                var marks = Path()
                marks.addEllipse(in: CGRect(x: frame.minX + 2, y: frame.maxY - 8, width: 10, height: 10))
                marks.addEllipse(in: CGRect(x: frame.minX - 2, y: frame.maxY + 2, width: 4, height: 4))
                return marks
            }
        }
    }
}

/// Layer animation keeps the pulse off SwiftUI's layout and update loop.
struct ChatTypingDots: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var still

    func makeNSView(context: Context) -> DotsView { DotsView() }
    func updateNSView(_ view: DotsView, context: Context) { view.still = still }
    static func dismantleNSView(_ view: DotsView, coordinator: ()) { view.stop() }

    final class DotsView: NSView {
        private let dots = (0..<3).map { _ in CALayer() }
        var still = false { didSet { if still != oldValue { refresh() } } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for dot in dots { layer?.addSublayer(dot) }
        }

        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            refresh()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refresh()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            refresh()
        }

        func stop() { dots.forEach { $0.removeAllAnimations() } }

        private func refresh() {
            var ink = NSColor.gray
            effectiveAppearance.performAsCurrentDrawingAppearance { ink = Palette.NS.ink.usingColorSpace(.sRGB) ?? .gray }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, dot) in dots.enumerated() {
                dot.frame = CGRect(x: CGFloat(index) * 12, y: (bounds.height - 8) / 2, width: 8, height: 8)
                dot.cornerRadius = 4
                dot.backgroundColor = ink.withAlphaComponent(0.55).cgColor
                dot.opacity = still ? 0.7 : 0.35
            }
            CATransaction.commit()
            guard !still, window != nil, bounds.width > 0 else { stop(); return }
            for (index, dot) in dots.enumerated() where dot.animation(forKey: "typing") == nil {
                let opacity = CAKeyframeAnimation(keyPath: "opacity")
                opacity.values = [0.35, 1, 0.35, 0.35]
                let scale = CAKeyframeAnimation(keyPath: "transform.scale")
                scale.values = [1, 1.06, 1, 1]
                let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
                rise.values = [0, 1, 0, 0]
                for animation in [opacity, scale, rise] {
                    animation.keyTimes = [0, 0.3, 0.6, 1]
                    animation.duration = 1.2
                    animation.timingFunctions = (0..<3).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
                }
                let pulse = CAAnimationGroup()
                pulse.animations = [opacity, scale, rise]
                pulse.duration = 1.2
                // Already in phase on arrival, rather than starting all three
                // at rest and waiting for their first pulse.
                pulse.beginTime = dot.convertTime(CACurrentMediaTime(), from: nil) - 1.2 + Double(index) * 0.2
                pulse.repeatCount = .infinity
                dot.add(pulse, forKey: "typing")
            }
        }
    }
}

/// What you said, as your line, nothing under or beside it: its
/// right-click menu edits it to send from there, or copies it.
private struct ChatBubble: View {
    let browser: Browser
    let item: ChatItem
    /// Its chat, when it may be edited: a turn's head, the agent not at work.
    var editIn: String? = nil
    /// The pasted text opened under its chip.
    @State private var openPaste: Int?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            // What went with it: its tabs and files, over your words.
            let lines = item.detail.split(separator: "\n").map(String.init)
            let carried = lines.filter { ["n:", "m:", "t:", "f:", "q:"].contains(String($0.prefix(2))) }
            // Text you pasted, each a chip that opens it (ChatPasted).
            let pasted = item.extra?["pasted"].map { $0.components(separatedBy: AgentLines.pasteMark) } ?? []
            // Images it went with, small, as they were sent.
            let pictures = lines.filter { $0.hasPrefix("i:") }.map { String($0.dropFirst(2)) }
            if !pictures.isEmpty {
                HStack(spacing: 6) {
                    Spacer(minLength: 48)
                    ForEach(pictures, id: \.self) { path in ChatThumb(path: path, group: pictures) }
                }
                .padding(.bottom, 4)
            }
            // A row of Now handed over (Do It): the row itself, over "Do It".
            if let handed = SyncHanded.parse(item.detail) {
                HStack {
                    Spacer(minLength: 48)
                    HandedCard(handed: handed)
                }
                .padding(.trailing, MessageBubble.tailRoom) // design: its end on your bubble's body, not its tail
                .padding(.bottom, 4)
            }
            if !carried.isEmpty || !pasted.isEmpty {
                HStack(spacing: 6) {
                    Spacer(minLength: 48)
                    ForEach(pasted.indices, id: \.self) { index in
                        ChatPasteChip(text: pasted[index], open: openPaste == index) {
                            openPaste = openPaste == index ? nil : index
                        }
                    }
                    ForEach(carried, id: \.self) { label in
                        HStack(spacing: 4) {
                            if label.hasPrefix("t:") {
                                let parts = label.dropFirst(2).split(separator: "|", maxSplits: 1).map(String.init)
                                SiteMark(host: parts.first ?? "", size: 12)
                                Text(parts.last ?? "").lineLimit(1)
                            } else if label.hasPrefix("q:") {
                                Text(String(label.dropFirst(2))).lineLimit(1)
                            } else if label.hasPrefix("n:") {
                                let parts = label.dropFirst(2).split(separator: "|", maxSplits: 1).map(String.init)
                                ChatFolderMark(nest: browser.nests.first { $0.id.uuidString == parts.first }, size: 14)
                                Text(parts.last ?? "").lineLimit(1)
                            } else if label.hasPrefix("m:") {
                                Symbol("envelope", size: 11).foregroundStyle(Palette.muted)
                                Text(String(label.dropFirst(2))).lineLimit(1)
                            } else {
                                Symbol(ChatAttachment.picture(URL(fileURLWithPath: String(label.dropFirst(2)))) ? "photo" : "doc", size: 11)
                                    .foregroundStyle(Palette.muted)
                                Text(String(label.dropFirst(2))).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink.opacity(0.75))
                        .padding(.horizontal, 6)
                        .frame(maxWidth: 190, minHeight: 22)
                        .background(Palette.ink.opacity(0.05), in: Capsule())
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.trailing, MessageBubble.tailRoom) // design: their end on your bubble's body, not its tail
                .padding(.bottom, 4)
            }
            if let open = openPaste, pasted.indices.contains(open) {
                ChatPasted(text: pasted[open])
                    .padding(.leading, 48) // design: as far in as your words' bubble may start
                    .padding(.trailing, MessageBubble.tailRoom) // design: their end on your bubble's body, not its tail
                    .padding(.bottom, 4)
            }
            if !item.text.isEmpty {
            HStack {
                Spacer(minLength: 48)
                if let command = ChatBubble.command(item.text, in: browser) {
                    // A command, as the ⌘J field shows it: its mark and name on the accent.
                    HStack(spacing: 6) {
                        Symbol(SelectionLayer.symbol(command.id), size: 11)
                        Text(item.text).lineLimit(2)
                    }
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                } else {
                    // The line the field's words fly into, as in the ⌘J field (SentWords).
                    SentWords(item.text, bubble: true)
                }
            }
            }
        }
        .contextMenu {
            ChatBubbleActions(browser: browser, item: item, chat: editIn)
        }
    }
}

/// Session changes affect the menu's actions, not every completed turn's text.
private struct ChatBubbleActions: View {
    let browser: Browser
    let item: ChatItem
    let chat: String?
    @ObservedObject private var agents = Agents.shared

    var body: some View {
        if let chat, agents.session(chat)?.state.live != true, agents.followUpProblem(chat) == nil {
            Button("Edit") { browser.editChat(chat, item) }
        }
        Button("Copy") { ChatCopy.put(item.text) }
    }
}

/// A row of Now handed to the agent, over your "Do It", read top down:
/// where it came from (the site's mark, "Gmail · From Now"), the row's
/// words, the gray line under them, every line on one edge. Yab for iPhone
/// draws the same card (HandedCard there) from the same line.
struct HandedCard: View {
    let handed: SyncHanded

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if handed.host.isEmpty {
                    Symbol("envelope", size: 10).foregroundStyle(Palette.faint).frame(width: 14, height: 14)
                } else {
                    SiteMark(host: handed.host, size: 14)
                }
                Text(handed.from)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
            }
            Text(handed.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            if !handed.detail.isEmpty {
                Text(handed.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .cardFrame()
    }
}

/// An image a message went with: read small off the main thread, once,
/// never the whole picture for a thumbnail's sake. A click looks at it in
/// Quick Look over Yab, the turn's other pictures a ← → away.
struct ChatThumb: View {
    let path: String
    /// The pictures it stands among, in order; alone when empty.
    var group: [String] = []
    /// Smaller where it stands among other things (the summary's sources).
    var height: CGFloat = ChatThumb.height
    @State private var image: NSImage?
    static let height: CGFloat = 72
    private static let kept = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Palette.ink.opacity(0.05)
            }
        }
        .frame(width: height * 1.3, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Palette.ink.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            let all = group.isEmpty ? [path] : group
            ChatQuickLook.shared.show(all.map { URL(fileURLWithPath: AgentLines.localPath($0)) }, at: all.firstIndex(of: path) ?? 0)
        }
        .task(id: path) { image = await Self.load(path) }
    }

    static func load(_ path: String) async -> NSImage? {
        if let hit = kept.object(forKey: path as NSString) { return hit }
        let made: NSImage? = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: AgentLines.localPath(path)) as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: Int(height * 1.3 * 2)]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: thumb, size: NSSize(width: thumb.width / 2, height: thumb.height / 2))
        }.value
        if let made { kept.setObject(made, forKey: path as NSString) }
        return made
    }
}

extension ChatBubble {
    /// The selection command these words name, when they are one's title.
    @MainActor static func command(_ words: String, in browser: Browser) -> SelectionCommand? {
        browser.selectionCommands.commands.first { $0.id != "ask" && SelectionCommand.menuTitle($0.name) == words }
    }
}

/// Copy, and "Copied" a moment after.
private struct ChatCopy: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            ChatCopy.put(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: { Symbol(copied ? "checkmark" : "doc.on.doc", size: 12) }
            .buttonStyle(.yab(.quiet, .small, icon: .square))
            .focusable(false)
            .keyTip(copied ? "Copied" : "Copy")
    }

    /// The words on the clipboard, as Copy in a message's menu puts them.
    static func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: the agent's words

/// The agent's own words, its Markdown kept: headings, lists, tables and
/// code as blocks of their own, what is inside them as rich text. Each
/// block is its own view, equal while its words are: while an answer is
/// written only its last block is drawn again, and what is not closed yet
/// there, a ** or a [link], waits.
struct ChatWords: View {
    let text: String
    let streaming: Bool
    /// Real partial messages are already paced by their transport/feed. A
    /// buffered complete message still gets the normal lump reveal.
    var partial = false
    /// Its words' size: the column's, or the ⌘J field's a size up.
    var size: CGFloat = 13.5
    /// Words that came just now: a lump of them is written out (WriteOut).
    /// Words read again later stand at once.
    var fresh = false
    /// Said in the column: each paragraph a message of its own, as
    /// Messages shows them; a table, code or a line of counts between.
    var bubbles = false
    /// Its last message has the tail: none when another follows it.
    var tail = true
    /// Come where the typing capsule stood: its first message is that
    /// capsule growing to its frame (Motion.reshape), already the size its
    /// words will be when written out.
    var grow = false
    @State private var out: WriteOut?
    /// Grow's three beats: the dots and the capsule's round marks gone in
    /// the first 0.1 s, the frame grown, the words in over the last two
    /// thirds; settled, its bubble drawn as any other.
    @State private var settled = false
    @State private var grown = false
    @State private var dotsOut = false
    @State private var inked = false
    @State private var renderedText: String?

    init(text: String, streaming: Bool, partial: Bool = false, size: CGFloat = 13.5, fresh: Bool = false,
         bubbles: Bool = false, tail: Bool = true, grow: Bool = false) {
        self.text = text
        self.streaming = streaming
        self.partial = partial
        self.size = size
        self.fresh = fresh
        self.bubbles = bubbles
        self.tail = tail
        self.grow = grow
        let count = fresh && !partial ? CodexVisualize.stripped(text).count : 0
        // Start before the first frame, rather than briefly drawing the
        // whole answer and erasing it again in onAppear.
        _out = State(initialValue: fresh && count > WriteOut.lump ? WriteOut(from: 0, to: count, start: Date()) : nil)
    }

    /// Do not type an arriving stream a second time. Besides lagging behind
    /// its provider, that would lay out both the full answer and its growing
    /// prefix on every animation tick. FreshText keeps its existing ink fade.
    private var reveal: WriteOut? { partial ? nil : out }

    /// Its words, Codex's markers (CodexVisualize) never among them, even
    /// while its answer is still coming in.
    private var words: String { CodexVisualize.stripped(text) }

    var body: some View {
        // Ticks only while a lump is being written out.
        TimelineView(.animation(minimumInterval: WriteOut.tick, paused: reveal == nil)) { context in
            let text = words
            let shown = reveal.map { String(text[..<WriteOut.stop(text, at: $0.count(at: context.date))]) } ?? text
            let writing = streaming || reveal != nil
            // In the column the line of counts isn't said: a turn's steps
            // are never shown.
            let blocks = blocksForDisplay(shown, writing: writing)
            ZStack(alignment: .topLeading) {
                if reveal != nil {
                    // Reserve the whole known answer, including every later
                    // paragraph and table. Cards below it never ride down as
                    // WriteOut reveals more of text we already received.
                    layout(blocksForDisplay(text, writing: streaming), writing: false, reserving: true)
                        .hidden()
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                layout(blocks, writing: writing)
            }
        }
        .font(.system(size: size))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if grow { growFromCapsule() }
        }
        .onChange(of: words) { old, new in
            guard !partial else { if out != nil { out = nil }; return }
            let now = Date()
            if let going = out {
                let at = going.count(at: now)
                out = new.count > at ? WriteOut(from: at, to: new.count, start: now) : nil
            } else if new.count - old.count > WriteOut.lump, new.hasPrefix(old) {
                // A lump more of the same words, not the same words drawn
                // anew (a notebook's links put in).
                out = WriteOut(from: old.count, to: new.count, start: now)
            }
        }
        .onChange(of: partial) { _, partial in
            if partial, out != nil { out = nil }
        }
        // Written out: the words stand as any others.
        .task(id: out) {
            guard let end = reveal?.end else { return }
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            if !Task.isCancelled { out = nil }
        }
        .preference(key: WritingOut.self, value: reveal != nil)
        .task(id: RenderState(text: text, ready: !streaming && reveal == nil && (!grow || settled))) {
            guard !streaming, reveal == nil, !grow || settled else { return }
            // FreshText's last letters fade for 150 ms. Report readiness
            // after that frame has settled, not merely when WriteOut ends.
            if fresh {
                do { try await Task.sleep(for: .milliseconds(160)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            renderedText = text
        }
        .preference(key: Rendered.self, value: renderedText == text && !streaming && reveal == nil && (!grow || settled) ? [text] : [])
    }

    private func blocksForDisplay(_ text: String, writing: Bool) -> [Block] {
        Self.blocks(text, streaming: writing).filter { block in
            guard bubbles, case .words(let words) = block else { return true }
            return !Self.counts(words)
        }
    }

    @ViewBuilder
    private func layout(_ blocks: [Block], writing: Bool, reserving: Bool = false) -> some View {
        if bubbles {
            let parts = ChatWords.parts(blocks)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(parts.indices, id: \.self) { part in
                    let indices = parts[part]
                    let content = VStack(alignment: .leading, spacing: 8) {
                        ForEach(indices, id: \.self) { index in
                            // Only the words still being written fade in as they come.
                            ChatBlock(block: blocks[index], fresh: writing && index == blocks.count - 1, size: size).equatable()
                        }
                    }
                    if ChatWords.said(blocks[indices[0]]) {
                        // Its tail on the last of a run, as Messages does.
                        let tail = part == parts.count - 1 ? self.tail : !ChatWords.said(blocks[parts[part + 1][0]])
                        let morph = !reserving && grow && !settled && part == 0
                        HStack(spacing: 0) {
                            ZStack(alignment: .topLeading) {
                                if !reserving, grow, part == 0, reveal != nil, let whole = Self.first(words) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(whole.indices, id: \.self) { ChatBlock(block: whole[$0], size: size).equatable() }
                                    }
                                    .hidden()
                                }
                                content
                            }
                                .fixedSize(horizontal: false, vertical: true)
                                .opacity(morph && !inked ? 0 : 1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .padding(.leading, MessageBubble.tailRoom) // design: the tail's room, on its side only
                                .background {
                                    if morph {
                                        ChatGrowth(grown: grown, dotsOut: dotsOut, tail: tail)
                                    } else {
                                        MessageBubble(mine: false, tail: tail).fill(Palette.ink.opacity(0.07))
                                    }
                                }
                                .padding(.bottom, tail ? MessageBubble.tailDrop : 0) // design: its tail hangs under the foot
                            Spacer(minLength: 40)
                        }
                    } else {
                        // A table read as rows of cards gets a card of its
                        // own, as the grid has, between the messages.
                        // On the bubbles' body, 6 in from each side; 8
                        // from the messages round it, and from what
                        // follows the answer (the turn adds the rest).
                        let last = part == parts.count - 1
                        if case .table(let rows) = blocks[indices[0]], (rows.first?.count ?? 0) > 3 {
                            content
                                .padding(.horizontal, 12)
                                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Palette.ink.opacity(0.08), lineWidth: 1))
                                .padding(.top, 4)
                                .padding(.bottom, last ? 0 : 4)
                                .padding(.horizontal, MessageBubble.tailRoom)
                        } else {
                            content
                                .padding(.top, 4)
                                .padding(.bottom, last ? 0 : 4)
                                .padding(.horizontal, MessageBubble.tailRoom)
                        }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(blocks.indices, id: \.self) { index in
                    // Only the words still being written fade in as they come.
                    ChatBlock(block: blocks[index], fresh: writing && index == blocks.count - 1, size: size).equatable()
                }
            }
        }
    }

    /// The capsule's growth, each beat on its own curve; its own bubble
    /// drawn plainly again once grown.
    private func growFromCapsule() {
        withAnimation(.linear(duration: 0.1)) { dotsOut = true }
        withAnimation(Motion.reshape, completionCriteria: .logicallyComplete) { grown = true } completion: { settled = true }
        withAnimation(.easeOut(duration: 0.2).delay(0.1)) { inked = true }
    }

    /// The blocks of an answer's first message, as written out whole.
    static func first(_ text: String) -> [Block]? {
        let blocks = ChatWords.blocks(CodexVisualize.stripped(text)).filter { block in
            guard case .words(let words) = block else { return true }
            return !counts(words)
        }
        return parts(blocks).first.map { $0.map { blocks[$0] } }
    }

    /// An answer that opens with words said in a bubble, not a table or
    /// code: the typing capsule can grow into it.
    static func opensSaid(_ text: String) -> Bool {
        first(text)?.first.map(said) ?? false
    }

    /// Words being written out under here (WriteOut): what follows an
    /// answer, what can be done with it, comes once they are.
    struct WritingOut: PreferenceKey {
        static let defaultValue = false
        static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
    }

    private struct RenderState: Equatable {
        let text: String
        let ready: Bool
    }

    struct Rendered: PreferenceKey {
        static let defaultValue: Set<String> = []
        static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) { value.formUnion(nextValue()) }
    }

    /// The blocks as messages: a heading or a paragraph each its own,
    /// a list together with the short line that leads into it; a table,
    /// code or a line of counts each on its own, out of any bubble.
    static func parts(_ blocks: [Block]) -> [[Int]] {
        var out: [[Int]] = []
        for (index, block) in blocks.enumerated() {
            // Math set apart is part of what leads into it.
            if case .math = block, let last = out.last?.last, said(blocks[last]) {
                out[out.count - 1].append(index)
                continue
            }
            if case .item = block, let last = out.last?.last, said(blocks[last]) {
                switch blocks[last] {
                case .item:
                    out[out.count - 1].append(index)
                    continue
                case .words(let words) where words.count < 60 && out[out.count - 1].count == 1:
                    out[out.count - 1].append(index)
                    continue
                default: break
                }
            }
            out.append([index])
        }
        return out
    }

    /// A block said as a message, not one standing between them.
    static func said(_ block: Block) -> Bool {
        switch block {
        case .table, .code: return false
        case .words(let words): return !counts(words)
        default: return true
        }
    }

    /// A closing line of counts: "3 checked · 1 skipped", in whatever
    /// language the answer is ("4 steps done · 0 sites skipped").
    static func counts(_ words: String) -> Bool {
        words.hasPrefix("~ ") || words.range(of: #"^\d+ (\w+ )?checked"#, options: .regularExpression) != nil
            || words.range(of: #"^\d+ [^\n·:]{1,40}( · \d+ [^\n·:]{1,40})+(:[^\n]*)?$"#, options: .regularExpression) != nil
    }

    /// The counts without the ones that are nothing: "4 checked", not
    /// "4 checked · 0 skipped".
    static func counted(_ words: String) -> String {
        let line = words.hasPrefix("~ ") ? String(words.dropFirst(2)) : words
        let (counts, rest) = line.firstIndex(of: ":").map { (String(line[..<$0]), String(line[$0...])) } ?? (line, "")
        let kept = counts.components(separatedBy: " \u{00B7} ").filter { !$0.hasPrefix("0 ") }
        return kept.isEmpty ? line : kept.joined(separator: " \u{00B7} ") + rest
    }

    enum Block: Equatable {
        case heading(String)
        case words(String)
        case item(String, mark: String)
        case table([[String]])
        case code(String)
        /// $$…$$ or \[…\] on lines of their own: math set apart.
        case math(String)
    }

    /// Markdown's blocks, as far as an answer uses them. Streaming, a table
    /// waits for the line under its head and each row for its end, and the
    /// last block holds back what it hasn't closed.
    static func blocks(_ text: String, streaming: Bool = false) -> [Block] {
        var out: [Block] = []
        var words: [String] = []
        var table: [[String]] = []
        var ruled = false
        var code: [String]?
        /// Math set apart being read: its lines so far, and what closes it.
        var math: (lines: [String], close: String)?
        var lines = text.components(separatedBy: "\n")
        // A row not ended yet isn't a row.
        if streaming, let tail = lines.last, tail.trimmingCharacters(in: .whitespaces).hasPrefix("|") { lines.removeLast() }
        func endTable() {
            if !table.isEmpty, ruled || !streaming { out.append(.table(table)) }
            table = []
            ruled = false
        }
        func flush() {
            if !words.isEmpty { out.append(.words(words.joined(separator: "\n"))); words = [] }
            endTable()
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let body = code {
                    out.append(.code(body.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if var open = math {
                if line.hasSuffix(open.close) {
                    let tail = String(line.dropLast(open.close.count))
                    out.append(.math((open.lines + [tail]).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                    math = nil
                } else {
                    open.lines.append(line)
                    math = open
                }
                continue
            }
            if let marks = [("$$", "$$"), ("\\[", "\\]")].first(where: { line.hasPrefix($0.0) }) {
                let (opener, closer) = marks
                let rest = String(line.dropFirst(opener.count))
                if let end = rest.range(of: closer) {
                    // On one line: math set apart only if nothing follows it.
                    if rest[end.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
                        flush()
                        out.append(.math(String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)))
                        continue
                    }
                } else {
                    flush()
                    math = ([rest], closer)
                    continue
                }
            }
            if line.hasPrefix("|") {
                if !words.isEmpty { out.append(.words(words.joined(separator: "\n"))); words = [] }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // The line under the head, dashes only.
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) { ruled = true; continue }
                table.append(cells)
                continue
            }
            endTable()
            if line.isEmpty { flush(); continue }
            if let heading = line.range(of: #"^#{1,4} "#, options: .regularExpression) {
                flush(); out.append(.heading(String(line[heading.upperBound...])))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("\u{2022} ") {
                flush(); out.append(.item(String(line.dropFirst(2)), mark: "\u{2022}"))
            } else if let number = line.range(of: #"^\d{1,2}[.)] "#, options: .regularExpression) {
                flush(); out.append(.item(String(line[number.upperBound...]), mark: String(line[number]).trimmingCharacters(in: .whitespaces)))
            } else {
                words.append(line)
            }
        }
        if let body = code { out.append(.code(body.joined(separator: "\n"))) }
        // Math not closed yet waits for the rest; an answer that never
        // closes it shows it as written.
        if let open = math, !streaming {
            words.append((open.close == "$$" ? "$$" : "\\[") + (open.lines.first ?? ""))
            words.append(contentsOf: open.lines.dropFirst())
        }
        flush()
        if streaming, let last = out.popLast() {
            switch last {
            case .words(let words): out.append(.words(settled(words)))
            case .item(let words, let mark): out.append(.item(settled(words), mark: mark))
            case .heading(let words): out.append(.heading(settled(words)))
            default: out.append(last)
            }
        }
        return out
    }

    /// Words as far as their marks are closed: an odd ** or a link still
    /// being written waits for the rest.
    static func settled(_ words: String) -> String {
        var text = words
        if text.components(separatedBy: "**").count % 2 == 0, let open = text.range(of: "**", options: .backwards) {
            text = String(text[..<open.lowerBound])
        }
        // Math still being written: not shown as TeX first.
        if text.components(separatedBy: "$$").count % 2 == 0, let open = text.range(of: "$$", options: .backwards) {
            text = String(text[..<open.lowerBound])
        }
        for (open, close) in [("\\(", "\\)"), ("\\[", "\\]")] {
            if let start = text.range(of: open, options: .backwards), text.range(of: close, range: start.upperBound..<text.endIndex) == nil {
                text = String(text[..<start.lowerBound])
            }
        }
        if let open = text.range(of: "[", options: .backwards) {
            let rest = text[open.upperBound...]
            let closed = rest.range(of: "](").map { rest[$0.upperBound...].contains(")") } ?? false
            if !closed, !(rest.contains("]") && !rest.contains("](")) { text = String(text[..<open.lowerBound]) }
        }
        return text
    }
}

/// Words written out as they would have streamed. An answer often comes
/// in one lump: the model writes it while it thinks, and Claude Code hands
/// it over whole a moment before the turn ends, so it stood there at once,
/// all of it. A lump is written out a few words at a time, twelve times a
/// second, as fast as it takes to be done in a second or so (never slower
/// than 240 characters a second); words that come a few at a time show as
/// they come.
struct WriteOut: Equatable {
    /// Characters shown as this stretch began, and once it is written.
    var from: Int
    var to: Int
    var start: Date
    /// Characters a second.
    var pace: Double

    /// More than this at once is a lump.
    static let lump = 40
    /// How often it writes more: the pace words come at in the column (ChatFeed).
    static let tick: TimeInterval = 1.0 / 12

    init(from: Int, to: Int, start: Date) {
        self.from = from
        self.to = to
        self.start = start
        let length = Double(max(0, to - from))
        pace = max(240, length / min(1.4, max(0.5, length / 500)))
    }

    var end: Date { start.addingTimeInterval(Double(max(0, to - from)) / pace) }

    /// How many characters are written by `now`.
    func count(at now: Date) -> Int {
        min(to, from + Int(pace * max(0, now.timeIntervalSince(start))))
    }

    /// Where the words written stop: `count` characters in, carried on
    /// to the end of the word, so a word comes whole.
    static func stop(_ text: String, at count: Int) -> String.Index {
        guard let at = text.index(text.startIndex, offsetBy: max(0, count), limitedBy: text.endIndex) else { return text.endIndex }
        return text[at...].firstIndex(where: \.isWhitespace) ?? text.endIndex
    }
}

/// Rich text made once for each finished stretch of words.
@MainActor
enum RichMemo {
    private static var memo = RichTextCache()

    static func rich(_ words: String) -> AttributedString {
        memo.value(words) {
            // Its math kept out of Markdown's way, a mark in its place (MathTeX).
            AgentAnswer.rich(MathTeX.marked(words))
        }
    }

    static func text(_ words: String, size: CGFloat = 13.5) -> Text { text(rich(words), size: size) }

    /// Markdown emphasis keeps the surrounding size, with a lighter weight.
    /// A link wears its site's icon before it (AnswerLinks), math is set
    /// in its place (MathTeX); `size` is the words' own, for both.
    static func text(_ rich: AttributedString, size: CGFloat = 13.5) -> Text {
        var text = Text("")
        var last: URL?
        for run in rich.runs {
            var words = AttributedString(rich[run.range])
            var bold = false
            if var intent = run.inlinePresentationIntent, intent.contains(.stronglyEmphasized) {
                intent.remove(.stronglyEmphasized)
                words.inlinePresentationIntent = intent
                bold = true
            }
            var made = pieces(words, size: size)
            if bold { made = made.fontWeight(.semibold) }
            if let url = run.link, let host = AnswerLinks.host(url) {
                // One icon for a link, however many runs its words are.
                if url != last { text = text + AnswerLinks.shared.icon(host, size: size).customAttribute(LinkSpot(url: url)) }
                made = made.customAttribute(LinkSpot(url: url))
            }
            last = run.link
            text = text + made
        }
        return text
    }

    /// A run's words, with any math in them set as pictures in the line.
    private static func pieces(_ words: AttributedString, size: CGFloat) -> Text {
        let plain = String(words.characters)
        guard plain.contains(MathTeX.open) else { return Text(words) }
        let attributes = words.runs.first?.attributes ?? AttributeContainer()
        let ink = attributes[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self]
        return MathTeX.pieces(plain).reduce(Text("")) { text, piece in
            guard let math = piece.math else { return text + Text(AttributedString(piece.words, attributes: attributes)) }
            let made = MathTeX.text(math.tex, size: size, display: math.display)
            return text + (ink.map { made.foregroundStyle($0) } ?? made)
        }
    }
}

/// One block of an answer, drawn again only when its words change.
private struct ChatBlock: View, Equatable {
    let block: ChatWords.Block
    /// Still being written: its new words fade in (FreshText).
    var fresh = false
    /// The words' size, for the math and the links' icons among them.
    var size: CGFloat = 13.5

    var body: some View {
        switch block {
        case .heading(let words):
            // The words' own size and weight: an answer reads in one voice.
            self.words(words)
        case .words(let words) where ChatWords.counts(words):
            // A closing line of counts: "3 checked · 1 skipped".
            RichMemo.text(ChatWords.counted(words))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
        case .words(let words):
            self.words(words).lineSpacing(4)
        case .item(let words, let mark):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(mark).foregroundStyle(Palette.muted)
                self.words(words).lineSpacing(3)
            }
        case .code(let body):
            Text(body)
                .font(.system(size: 12, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        case .table(let rows):
            ChatTable(rows: rows)
        case .math(let tex):
            MathBlock(tex: tex, size: size)
        }
    }

    private func words(_ words: String) -> some View {
        AnswerWords(words: words, fresh: fresh, size: size)
        // Written out, the same words drawn plain: at once, never a
        // crossfade of the two (the turn's end animates around them).
        .transaction { $0.animation = nil }
    }
}

/// Math set apart: at its own size, and slid sideways when wider than
/// the column.
private struct MathBlock: View {
    let tex: String
    let size: CGFloat

    var body: some View {
        let picture = MathTeX.picture(tex, size: size, display: true)
        let image = Image(nsImage: picture.image).renderingMode(.template)
            .accessibilityLabel(tex)
        ViewThatFits(in: .horizontal) {
            image.padding(.vertical, 2)
            ThreadScrollView(.horizontal, showsIndicators: false) { image.padding(.vertical, 2) }
        }
    }
}

/// An answer's rich words: drawn again when a link's icon arrives, and
/// with tips over their links once written.
private struct AnswerWords: View {
    let words: String
    let fresh: Bool
    let size: CGFloat
    @ObservedObject private var links = AnswerLinks.shared

    var body: some View {
        if fresh {
            // No renderer while the words come: a renderer over streaming
            // words cost a third of a core (chat-motion). Tips once written.
            FreshText(rich: RichMemo.rich(words), size: size)
        } else if AnswerLinks.linked(words) {
            LinkedText(text: RichMemo.text(words, size: size))
        } else {
            RichMemo.text(words, size: size)
        }
    }
}


/// A table in a column 380 wide: up to three columns as a grid that wraps,
/// on a card of its own with its head on a tint, hairlines between the
/// rows, the first column a little heavier, numbers to the right; more than three, each row a
/// card: its first cell the title, its source at the right, the rest as
/// "label value" lines.
private struct ChatTable: View {
    let rows: [[String]]

    private var head: [String] { rows.first ?? [] }
    private var body_: [[String]] { Array(rows.dropFirst()) }

    var body: some View {
        if head.count <= 3 { grid } else { cards }
    }

    private var grid: some View {
        let numbers = head.indices.map { column in
            !body_.isEmpty && body_.allSatisfy { row in column < row.count && ChatTable.numeric(row[column]) }
        }
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(head.indices, id: \.self) { column in
                    RichMemo.text(head[column])
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        // Every cell of the head as tall as the tallest, its tint one band.
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: numbers[column] ? .trailing : .leading)
                        .background(Palette.ink.opacity(0.035))
                        .gridColumnAlignment(numbers[column] ? .trailing : .leading)
                }
            }
            ForEach(body_.indices, id: \.self) { index in
                Rectangle().fill(Palette.ink.opacity(0.07)).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow(alignment: .firstTextBaseline) {
                    ForEach(head.indices, id: \.self) { column in
                        let cell = column < body_[index].count ? body_[index][column] : ""
                        RichMemo.text(cell)
                            .font(.system(size: 13, weight: column == 0 ? .medium : .regular))
                            .monospacedDigit()
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: numbers[column] ? .trailing : .leading)
                    }
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(Palette.ink.opacity(0.08), lineWidth: 1))
    }

    /// No labels: the date small over the title, the long cells as words
    /// under it, the short ones and the source in a quiet line at the foot.
    private var cards: some View {
        let card = TableCards(rows)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(body_.indices, id: \.self) { index in
                let row = body_[index]
                let kicker = card.cell(row, card.kicker)
                let foot = card.footLine(row, head: head)
                let source = card.cell(row, card.source)
                VStack(alignment: .leading, spacing: 0) {
                    if !kicker.isEmpty {
                        RichMemo.text(kicker)
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                            .padding(.bottom, 2)
                    }
                    RichMemo.text(card.cell(row, card.title))
                        .font(.system(size: 13.5, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(card.words.filter { !card.cell(row, $0).isEmpty }, id: \.self) { column in
                        RichMemo.text(card.cell(row, column))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink.opacity(0.8))
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    if !foot.isEmpty || !source.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            RichMemo.text(foot)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if !source.isEmpty {
                                // The place it goes, by its own mark and name.
                                HStack(spacing: 4) {
                                    if let host = TableCards.host(source) { SiteMark(host: host, size: 12) }
                                    RichMemo.text(TableCards.named(source))
                                        .font(.system(size: 12.5))
                                        .lineLimit(1)
                                }
                                .fixedSize()
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(.vertical, 10)
                if index < body_.count - 1 {
                    Rectangle().fill(Palette.ink.opacity(0.07)).frame(height: 1)
                }
            }
        }
    }

    /// A cell that is a number, an amount or a share.
    static func numeric(_ cell: String) -> Bool { TableCards.numeric(cell) }
}

// MARK: the work

/// It waits on you: a question, a request handed to you, a press held for
/// your yes (AgentPermit). Said in the accent, with no light over it.
struct ChatWait: Equatable {
    /// The step that asks, in words; nil for a press held for your yes.
    var words: StepWords?
    var since: Date
    /// The step that asks, which the live line says: never a row as well.
    var step: String?
}

/// The live line's words, as the column's head says them (ChatLiveWords).
enum ChatLiveLine {
    /// A thinking summary's first line, its bold marks gone.
    static func gist(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
    }
}

/// The live line's words alone, for the column's head.
struct ChatLiveWords: View {
    let turn: [ChatItem]
    /// Bumped when what the line holds is due to change with nothing new
    /// from the agent.
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let live = ChatLive.shown(turn, at: Date())
        Text(ChatLive.words(turn, shown: live.shown))
            .task(id: live.next) {
                guard let next = live.next else { return }
                try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 0.01))
                if !Task.isCancelled { tick &+= 1 }
            }
    }
}

/// What the live line says, held so it never flickers. Steps often come a
/// few at once and are over in a tenth of a second (the page read, a look
/// at it, the task named), and a line that followed each one said three
/// things in a third of a second. Held, each thing it says stays a second
/// at least; a step over before its turn on the line still gets it, a
/// second after it ended; Yab's own bookkeeping gets the line only once it
/// has run a while. Worked out from the turn's steps and their times
/// alone, so the line, the steps over it and the column's head always say
/// the same. What asks you isn't held: the line says it at once (ChatWait).
enum ChatLive {
    /// The least each thing the line says stays.
    static let hold: TimeInterval = 1
    /// How long after it ended a step over before its turn still gets it.
    static let linger: TimeInterval = 1
    /// How long Yab's own bookkeeping runs before the line says it.
    static let quiet: TimeInterval = 0.4

    /// A step as the line weighs it.
    struct Step: Equatable {
        let id: String
        let began: Date
        /// Nil while it goes on.
        let ended: Date?
        /// Yab's own bookkeeping: memory, history, the task's name.
        var quiet = false
    }

    struct Shown: Equatable {
        /// The step it says; nil, it thinks.
        var step: String?
        /// Since when it says it, which its mark's gesture and the light
        /// through its words count from.
        var since: Date
    }

    /// What the line says at `now`, and when it may next say something
    /// else with nothing new from the agent.
    @MainActor static func shown(_ turn: [ChatItem], at now: Date) -> (shown: Shown, next: Date?) {
        let steps = turn.compactMap { item -> Step? in
            guard [.tool, .command, .edit, .subagent].contains(item.kind), let began = item.began else { return nil }
            let words = StepWords.of(item)
            if words.asks { return nil }
            return Step(id: item.id, began: began, ended: item.state == .running ? nil : item.ended ?? began, quiet: words.quiet)
        }
        return shown(steps, from: turn.first?.began ?? now, at: now)
    }

    /// The line played through from when its turn began.
    static func shown(_ steps: [Step], from start: Date, at now: Date) -> (shown: Shown, next: Date?) {
        var shown = Shown(step: nil, since: start)
        // Every moment it may change at: a step beginning or ending, its
        // moment after, Yab's own having run a while.
        var moments = Set<Date>()
        for step in steps {
            moments.insert(step.began)
            if step.quiet { moments.insert(step.began + quiet) }
            if let ended = step.ended {
                moments.insert(ended)
                moments.insert(ended + linger)
            }
        }
        let past = moments.filter { $0 <= now }.sorted()
        var index = 0
        // A change held back until what it says has stood its while.
        var due: Date?
        while true {
            let at: Date
            if let held = due, held <= now, index >= past.count || held <= past[index] {
                at = held
                due = nil
            } else if index < past.count {
                at = past[index]
                index += 1
            } else {
                break
            }
            let wanted = pick(steps, at: at, after: shown)
            guard wanted != shown.step else { continue }
            if at >= shown.since + hold {
                shown = Shown(step: wanted, since: at)
                due = nil
            } else {
                due = shown.since + hold
            }
        }
        let ahead = ([due].compactMap { $0 } + moments.filter { $0 > now }).min()
        return (shown, ahead)
    }

    /// What the line would say at `at`: the newest step going on; a step
    /// that came after the one it says and is over, for its moment; Yab's
    /// own, once it has run a while; else thinking.
    static func pick(_ steps: [Step], at: Date, after shown: Shown) -> String? {
        func going(_ step: Step) -> Bool { step.began <= at && (step.ended.map { $0 > at } ?? true) }
        if let step = steps.last(where: { !$0.quiet && going($0) }) { return step.id }
        let said = shown.step.flatMap { id in steps.first { $0.id == id }?.began } ?? shown.since
        if let step = steps.last(where: { step in
            !step.quiet && step.id != shown.step && step.began > said && step.began <= at
                && step.ended.map { $0 <= at && at < $0 + linger } == true
        }) { return step.id }
        if let step = steps.last(where: { $0.quiet && going($0) && at >= $0.began + quiet }) { return step.id }
        return nil
    }

    /// A step as the line says it: going on, its beat from when the line
    /// took it up.
    static func going(_ item: ChatItem, since: Date) -> ChatItem {
        var item = item
        item.state = .running
        item.began = since
        item.ended = nil
        return item
    }

    /// The line's words alone: what the column's head says under the name.
    @MainActor static func words(_ turn: [ChatItem], shown: Shown) -> String {
        if let id = shown.step, let item = turn.last(where: { $0.id == id }) { return StepWords.of(item).line(.running) }
        let thought = turn.last.map { $0.kind == .thinking ? ChatLiveLine.gist($0.text) : "" } ?? ""
        return thought.isEmpty ? "Thinking" : thought
    }
}

/// What a step was about, in gray: a site, a file, “words”, a question;
/// keys drawn as keys; a command or a path cut in its middle, words at
/// their end.
private struct ChatObject: View {
    let words: StepWords
    var extra = ""

    var body: some View {
        if let keys = words.keys {
            HStack(spacing: 4) {
                KeyGlyphs(keys: ChatObject.glyphs(keys), size: 11.5, tint: Palette.muted)
                if !extra.isEmpty { Text(extra).foregroundStyle(Palette.muted) }
            }
        } else {
            Text(words.object + extra)
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(words.middle ? .middle : .tail)
        }
    }

    /// Keys as the stream has them ("Meta+a", "Tab Tab Enter"), as marks.
    static func glyphs(_ keys: String) -> String {
        keys.split(separator: " ").map { chord in
            chord.split(separator: "+").map { key -> String in
                switch key.lowercased() {
                case "enter", "return": return "\u{21A9}"
                case "tab": return "\u{21E5}"
                case "backspace", "delete": return "\u{232B}"
                case "escape", "esc": return "esc"
                case "meta", "cmd", "command": return "\u{2318}"
                case "shift": return "\u{21E7}"
                case "alt", "option": return "\u{2325}"
                case "control", "ctrl": return "\u{2303}"
                case "arrowup": return "\u{2191}"
                case "arrowdown": return "\u{2193}"
                case "arrowleft": return "\u{2190}"
                case "arrowright": return "\u{2192}"
                case "space": return "space"
                default: return key.count == 1 ? key.uppercased() : String(key)
                }
            }.joined()
        }.joined()
    }
}

/// Every step: done ones in the past tense, running ones in the present
/// with their mark moving, a failed one with why under it, and a command's
/// last lines a click away.
struct ChatSteps: View {
    let browser: Browser
    let chat: Chat
    let steps: [ChatItem]
    let working: Bool
    /// How its turn ended: a step still going when it failed didn't get
    /// done; one going when you stopped it was stopped.
    var ending = "done"
    @State private var shown: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ChatSteps.runs(steps), id: \.[0].id) { run in
                row(run)
            }
        }
    }

    @ViewBuilder private func row(_ run: [ChatItem]) -> some View {
        let item = run[0]
        let words = StepWords.of(item)
        // A step left running when its turn ended: not done if it failed,
        // stopped where you stopped it.
        // Still going in the background (ClaudeLines): running until its notice.
        let background = item.extra?["task"] != nil && item.state == .running
        let left = item.state == .running && !working && !background
        let state: ChatItem.State = left ? (ending == "failed" ? .failed : ending == "stopped" ? .running : .done) : item.state
        let running = state == .running && !left && !background
        let declined = item.extra?["declined"] != nil
        let extra = run.count > 1 ? " \u{00B7} \(run.count) times" : ""
        let line = HStack(spacing: 8) {
            ChatStepMark(item: item, words: words, live: running, failed: state == .failed)
            Text(words.verb(state))
                .glint(running && !words.asks, anchor: item.began)
                .foregroundStyle(state == .failed || left ? Palette.muted : running && words.asks ? Palette.ink : Palette.ink.opacity(0.75))
            ChatObject(words: words, extra: extra)
            Spacer(minLength: 4)
            if state == .failed {
                Text("failed").foregroundStyle(ButtonCSS.danger)
            } else if background {
                Text("in background").foregroundStyle(Palette.muted)
            } else if item.extra?["stopped"] != nil || (left && ending == "stopped") {
                Text("stopped").foregroundStyle(Palette.muted)
            } else if let took = ChatSteps.took(item) {
                Text(took).foregroundStyle(Palette.muted).monospacedDigit()
            }
        }
        .font(.system(size: 13))
        .frame(height: 22)
        .contentShape(Rectangle())
        VStack(alignment: .leading, spacing: 2) {
            if let tab = ChatSteps.tab(for: item, in: chat, browser: browser) {
                Button { browser.select(tab) } label: { line }
                    .buttonStyle(.plain)
                    .keyTip("Go to this tab")
            } else if item.kind == .command, !item.text.isEmpty {
                Button { if shown.contains(item.id) { shown.remove(item.id) } else { shown.insert(item.id) } } label: { line }
                    .buttonStyle(.plain)
                    .keyTip(shown.contains(item.id) ? "Hide what it printed" : "Show what it printed")
            } else if item.kind == .subagent, state != .failed, !item.text.isEmpty {
                // Its report, folded under it (ChatReport).
                Button { if shown.contains(item.id) { shown.remove(item.id) } else { shown.insert(item.id) } } label: { line }
                    .buttonStyle(.plain)
                    .keyTip(shown.contains(item.id) ? "Hide its report" : "Show its report")
            } else {
                line
            }
            if state == .failed || declined, let why = ChatSteps.why(item) {
                Text(why)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(.leading, 22) // design: under the verb, past the mark's 14 and its gap of 8
                    .padding(.bottom, 2)
            }
            if item.kind == .command, shown.contains(item.id), !item.text.isEmpty {
                ChatOutput(text: item.text, failed: state == .failed)
                    .padding(.leading, 22) // design: under the verb, past the mark's 14 and its gap of 8
                    .padding(.vertical, 2)
            }
            if item.kind == .subagent, state != .failed, shown.contains(item.id), !item.text.isEmpty {
                ChatReport(text: item.text)
                    .padding(.leading, 22) // design: under the verb, past the mark's 14 and its gap of 8
                    .padding(.vertical, 2)
            }
        }
    }

    /// How long a command or a subagent took, once it is two seconds or more.
    static func took(_ item: ChatItem) -> String? {
        guard [.command, .subagent].contains(item.kind), item.state != .running,
              let began = item.began, let ended = item.ended, ended.timeIntervalSince(began) >= 2 else { return nil }
        return Chat.span(ended.timeIntervalSince(began))
    }

    /// Why a step failed, in its own words: a command's telling line from
    /// the end of what it printed, another step's first.
    static func why(_ item: ChatItem) -> String? {
        let lines = item.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let line = item.kind == .command
            ? lines.last { $0.lowercased().contains("error") } ?? lines.last!
            : lines.first!
        return line.count > 160 ? String(line.prefix(159)) + "\u{2026}" : line
    }

    /// A step that opened a page takes you to its tab, while it is open.
    static func tab(for item: ChatItem, in chat: Chat, browser: Browser) -> Tab? {
        guard item.kind == .tool, ["open", "navigate"].contains(item.name), !item.detail.isEmpty else { return nil }
        let ids = Set(chat.tabs.map(\.id))
        return browser.tabs.first { ids.contains($0.id.uuidString) && $0.address?.host() == item.detail }
    }

    /// Steps in a row that did the same to the same, as one.
    static func runs(_ steps: [ChatItem]) -> [[ChatItem]] {
        var out: [[ChatItem]] = []
        for step in steps {
            if let last = out.last?.first, last.kind == step.kind, last.name == step.name, last.detail == step.detail, step.state != .running, last.state == step.state {
                out[out.count - 1].append(step)
            } else {
                out.append([step])
            }
        }
        return out
    }

    /// The sites a turn worked on, in the order it came to them.
    @MainActor static func hosts(_ steps: [ChatItem]) -> [String] {
        var out: [String] = []
        for step in steps where step.kind == .tool || step.kind == .subagent {
            for host in StepWords.hosts(step.detail, page: step.page).map(StepWords.bare) where !out.contains(host) { out.append(host) }
            if let site = StepWords.of(step).site, !out.contains(site) { out.append(site) }
        }
        return out
    }

    /// "Used afuri.com, tabelog.com and 2 more"; with no site, what kinds
    /// of work: "Read files, ran commands and edited a file".
    @MainActor static func used(_ steps: [ChatItem]) -> String {
        let hosts = hosts(steps)
        guard hosts.isEmpty else {
            if hosts.count <= 2 { return "Used " + hosts.joined(separator: ", ") }
            return "Used \(hosts[0]), \(hosts[1]) and \(hosts.count - 2) more"
        }
        return means(steps)
    }

    /// What steps with no site to show were, in a phrase.
    @MainActor static func means(_ steps: [ChatItem]) -> String {
        var parts: [String] = []
        func add(_ words: String) { if !parts.contains(words) { parts.append(words) } }
        for step in steps {
            let words = StepWords.of(step)
            switch words.art {
            case .readFile, .folder, .skill: add("read files")
            case .search: add(["WebSearch", "web_search"].contains(step.name) ? "searched the web" : "searched files")
            case .command, .code: add("ran commands")
            case .edit: add(step.kind == .edit ? "edited files" : "wrote things down")
            case .robot: add("worked with subagents")
            case .mail: add("went through mail")
            case .hand: add("asked you")
            case .done: break
            case .mcp: add("used tools")
            default: add("worked on pages")
            }
        }
        guard let first = parts.first else { return "Worked" }
        let words = parts.count == 1 ? first : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// A command's last lines, as it printed them.
private struct ChatOutput: View {
    let text: String
    let failed: Bool

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(8).joined(separator: "\n")
        VStack(alignment: .leading, spacing: 4) {
            Text(lines)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Palette.ink.opacity(0.75))
                .lineSpacing(1)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(failed ? "Failed" : "Done")
                .font(.system(size: 11.5))
                .foregroundStyle(failed ? ButtonCSS.danger : Palette.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// A turn that couldn't finish: the cause, its recovery, and a short code.
/// Provider details stay folded away and the original stays in the chat log.
private struct ChatFailure: View {
    let browser: Browser
    let chat: Chat
    let raw: String
    let agent: String
    /// What went with the words that failed (Session.sent).
    var sent: [ChatAttachment] = []
    let retry: (() -> Void)?
    /// The same words again without one of what went with them.
    var without: ((ChatAttachment) -> Void)? = nil

    var body: some View {
        let problem = ChatProblem(raw, agent: agent)
        // A file the error names, or one gone since: said by name, as Dia's.
        let blamed = without == nil ? nil : ChatAttachment.blamed(raw, among: sent)
        HStack(alignment: .top, spacing: 8) {
            StepMark(art: .fail, tint: ButtonCSS.danger)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                if let blamed, let url = blamed.file {
                    Text(blamed.trouble() ?? "\(agent) couldn\u{2019}t read \u{201C}\(url.lastPathComponent)\u{201D}.")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(problem.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text(problem.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(problem.code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let blamed, let without {
                        Button("Ask Without It") { without(blamed) }
                            .buttonStyle(.yab(.secondary, .small))
                    }
                    if blamed == nil, problem.recovery != .retry || retry != nil {
                        Button(problem.action) {
                            switch problem.recovery {
                            case .model: ChatModelLine.choose(browser: browser, chat: chat, retry: retry)
                            case .account: SettingsWindow.shared.show(.models, for: browser)
                            case .retry: retry?()
                            }
                        }
                            .buttonStyle(.yab(.secondary, .small))
                    }
                }
                if !problem.diagnostics.isEmpty {
                    DisclosureGroup("Details") {
                        Text(problem.diagnostics)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A step's mark: its site's icon where it went to a site, else the
/// drawing of its kind, moving while it runs (StepMark).
struct ChatStepMark: View {
    let item: ChatItem
    let words: StepWords
    var live = false
    /// Didn't get done: its own failure, or its turn's.
    var failed = false

    var body: some View {
        let hosts = StepWords.hosts(item.detail, page: item.page).map(StepWords.bare)
        let failed = failed || item.state == .failed
        if let site = words.site, !failed {
            // Several at once, overlapping, up to three.
            HStack(spacing: -5) {
                ForEach((hosts.count > 1 ? hosts : [site]).prefix(3), id: \.self) { SiteMark(host: $0, size: 14) }
            }
        } else {
            let fresh = (item.ended ?? item.began).map { Date().timeIntervalSince($0) < 1.5 } ?? false
            StepMark(art: failed ? .fail : words.art,
                     tint: failed ? ButtonCSS.danger : words.asks && item.state == .running ? .accentColor : Palette.muted,
                     live: live && item.state == .running, anchor: item.began, fresh: fresh)
        }
    }

    /// A host as the line says it, without its www.
    static func bare(_ host: String) -> String { StepWords.bare(host) }

    /// The tab a step names as "tab:<id>" (ChatItem.about), while it is open.
    static func tab(_ detail: String) -> Tab? {
        guard detail.hasPrefix("tab:") else { return nil }
        let id = String(detail.dropFirst(4)).lowercased()
        return Agents.shared.browser?.everyTab.first { Bench.short($0) == id }
    }
}

/// Several sites' icons over one another, each on a ring of the ground.
struct SiteStack: View {
    let hosts: [String]
    /// How far along each icon stands from the one before it.
    static let step: CGFloat = 13

    var body: some View {
        let shown = Array(hosts.prefix(3))
        // Each icon has the next one's ring cut out of it, so they part
        // with no ground drawn behind them: the column is glass, and no
        // ground matched it. The first icon's edge is the column's.
        ZStack(alignment: .leading) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, host in
                SiteMark(host: host, size: 14)
                    .mask { Ring(cut: index < shown.count - 1).fill(style: FillStyle(eoFill: true)) }
                    .offset(x: CGFloat(index) * Self.step)
            }
        }
        .frame(width: 14 + CGFloat(max(0, shown.count - 1)) * Self.step, height: 14, alignment: .leading)
    }

    /// An icon's mask: all of it, less the ring of 1.5 round the next icon.
    private struct Ring: Shape {
        let cut: Bool

        func path(in rect: CGRect) -> Path {
            var path = Path(rect)
            if cut {
                let next = CGRect(x: SiteStack.step - 1.5, y: -1.5, width: rect.width + 3, height: rect.height + 3)
                let corner = next.fitting(corner: Radius.small)
                path.addRoundedRect(in: next, cornerSize: CGSize(width: corner, height: corner), style: .continuous)
            }
            return path
        }
    }
}

/// A site's icon, or its first letter on a quiet tile until one is known.
struct SiteMark: View {
    let host: String
    var size: CGFloat = 14
    /// The tab's own icon, when there is a tab to take it from.
    var icon: NSImage? = nil
    @Environment(\.colorScheme) private var scheme

    /// A site's icon, or its parent's for a subdomain with none of its own:
    /// api.github.com wears GitHub's.
    @MainActor static func icon(_ host: String) -> NSImage? {
        var labels = host.split(separator: ".").map(String.init)
        while labels.count >= 2 {
            let name = labels.joined(separator: ".")
            if let hit = Favicons.shared.cached(name) ?? Favicons.shared.cached("www." + name) { return hit }
            labels.removeFirst()
        }
        return nil
    }

    @MainActor private static var darkness: [String: Bool] = [:]

    /// Whether an icon is dark all over, a black mark with nothing light in
    /// it: read once per site from a small drawing of it.
    @MainActor static func dark(_ icon: NSImage, _ host: String) -> Bool {
        if let known = darkness[host] { return known }
        var said = false
        let side = 16
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            var sum = 0.0, count = 0
            for x in 0..<side { for y in 0..<side {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5 else { continue }
                sum += 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                count += 1
            } }
            said = count > 20 && sum / Double(count) < 0.22
        }
        darkness[host] = said
        return said
    }

    var body: some View {
        Group {
            if let icon = icon ?? SiteMark.icon(host) {
                let image = Image(nsImage: icon).resizable().interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
                // A black mark on the dark: on a light tile, as its own page
                // would have it, or GitHub's cat is gone.
                if scheme == .dark, SiteMark.dark(icon, host) {
                    image.padding(1.5) // design: the light tile's ring round the mark, as SiteStack's
                        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                } else {
                    image
                }
            } else {
                Text(String(host.replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: size, height: size)
                    .background(Palette.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: what can be done with an answer

/// Under an answer: copy it, ask again, its tabs in words, and when it came.
/// A quiet trial that passed (Boosts.fit): the page before and after it,
/// pictures Yab took of its own page nobody saw, side by side.
struct ChatBoostPictures: View {
    let chat: String
    @ObservedObject private var boosts = Boosts.shared

    var body: some View {
        if let pair = boosts.pictures[chat] {
            HStack(alignment: .top, spacing: 6) {
                shot(pair.before, "Before", files: pair.files, at: 0)
                shot(pair.after, "After", files: pair.files, at: 1)
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    /// A click looks at it in Quick Look over Yab, as a message's pictures
    /// open (ChatThumb), the other one a ← → away.
    private func shot(_ image: NSImage, _ title: String, files: [URL], at index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .top) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5))
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if !files.isEmpty { ChatQuickLook.shared.show(files, at: index) } }
    }
}

/// When a turn was asked, as Messages stamps it: over the first turn and
/// over one that came 15 minutes or more after the one before, nowhere else.
enum ChatStamp {
    static let gap: TimeInterval = 15 * 60

    /// The turn at `index`'s stamp, if it has one.
    static func at(_ turns: [[ChatItem]], _ index: Int) -> Date? {
        guard turns.indices.contains(index), let at = turns[index].first(where: { $0.began != nil })?.began else { return nil }
        guard index > 0 else { return at }
        guard let before = turns[index - 1].compactMap({ $0.ended ?? $0.began }).max() else { return at }
        return at.timeIntervalSince(before) >= gap ? at : nil
    }

    /// "Today 14:09", "Yesterday 23:47", "Tuesday 9:15" within the week,
    /// else the date: "Oct 3 14:09", with its year when it isn't this one's.
    static func words(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = AppDates.locale) -> String {
        let time = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let day: String
        switch days {
        case ...0: day = "Today"
        case 1: day = "Yesterday"
        case 2...6: day = date.formatted(style.weekday(.wide))
        default:
            style = style.month(.abbreviated).day()
            if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
            day = date.formatted(style)
        }
        return day + " " + time
    }
}

/// An answer's actions, in its right-click menu, as Messages keeps a
/// message's: Copy, Ask Again, Repeat and its tabs; nothing
/// stands under it. `on`: once it is all written out.
private struct ChatAnswerMenu: ViewModifier {
    let browser: Browser
    let chat: Chat
    let asked: String?
    let answer: ChatItem
    let on: Bool
    @State private var work = false
    /// Repeat's tick: the routine keeps the chat's tabs as a folder.
    @State private var keepTabs = true

    func body(content: Content) -> some View {
        // Keep the content on the same structural path when its menu
        // becomes available. Replacing it here remounted ChatWords and
        // restarted WriteOut as soon as it had just finished.
        content
            .contextMenu {
                if on {
                    Button("Copy") { ChatCopy.put(answer.text) }
                    if let asked, Agents.shared.session(chat.id)?.state.live != true {
                        Button("Ask Again", mark: "yab.reload") { Agents.shared.followUp(chat.id, asked) }
                        // The same words again on their own, from now on: a routine.
                        if !Routines.shared.all.contains(where: { $0.chat == chat.id }) {
                            Menu("Repeat") {
                                let folder = keepTabs && !chat.tabs.isEmpty
                                ForEach(Routines.presets(at: answer.ended ?? answer.began ?? Date()), id: \.value) { preset in
                                    Button(preset.title) { Routines.shared.repeatChat(chat, asked: asked, when: preset.value, folder: folder, in: browser) }
                                }
                                Divider()
                                Button("Custom\u{2026}") { Routines.shared.repeatChatCustom(chat, asked: asked, folder: folder, in: browser) }
                                // Its tabs, kept up to date in a folder by the routine.
                                if !chat.tabs.isEmpty {
                                    Divider()
                                    Toggle(chat.tabs.count == 1 ? "Keep the Tab Up to Date" : "Keep the \(chat.tabs.count) Tabs Up to Date", isOn: $keepTabs)
                                }
                            }
                        }
                    }
                    if !chat.tabs.isEmpty {
                        Divider()
                        Button("Show Tabs") { work = true }
                    }
                }
            }
            .popover(isPresented: $work, arrowEdge: .bottom) {
                ChatWork(browser: browser, chat: chat) { work = false }
            }
    }
}

/// The tabs an answer's turn worked in, shown from its menu's Show Tabs.
/// Its steps are never shown: what it does is said only in the head.
private struct ChatWork: View {
    let browser: Browser
    let chat: Chat
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MailChipFlow {
                ForEach(chat.tabs) { ref in chip(ref) }
            }
            Button("Close All Tabs") {
                for ref in chat.tabs {
                    if let tab = browser.tabs.first(where: { $0.id.uuidString == ref.id }) { browser.close(tab) }
                }
                done()
            }
            .buttonStyle(.yab(.quiet, .small))
        }
        .padding(10)
        .frame(width: 340, alignment: .leading)
        // A popover's first row takes the keyboard's ring: a list to point at has none.
        .focusEffectDisabled()
    }

    private func chip(_ ref: Chat.TabRef) -> some View {
        let tab = browser.tabs.first { $0.id.uuidString == ref.id }
        return Button {
            if let tab { browser.select(tab) }
            done()
        } label: {
            HStack(spacing: 6) {
                Group {
                    if let icon = tab?.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        SiteMark(host: StepWords.bare(URL(string: ref.url)?.host() ?? ref.url), size: 12)
                    }
                }
                .frame(width: 12, height: 12)
                Text(ref.title.isEmpty ? ref.url : ref.title)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
                    .fixedSize()
            }
        }
        .buttonStyle(.yab(.secondary, .small))
        .keyTip("Go to this tab")
    }
}

// MARK: the light through the live line

extension View {
    /// The light passing through these words while what they say goes on
    /// (Glint), seen only through their own letters. Put it before the
    /// words' color, which it lights up to the ink.
    func glint(_ on: Bool = true, anchor: Date? = nil) -> some View {
        modifier(GlintLight(on: on, anchor: anchor))
    }
}

/// The band laid over the words and masked by them, so it lights their
/// letters and nothing around them. The mask is Core Animation's: the
/// band moves on the render server, and the main thread does nothing for
/// it.
private struct GlintLight: ViewModifier {
    let on: Bool
    let anchor: Date?

    func body(content: Content) -> some View {
        content.overlay {
            if on { Glint(anchor: anchor).mask { content.foregroundStyle(.black) } }
        }
    }
}

/// A band of ink passing through words (glint), once 0.6 s into their
/// step and then every four, the beat their mark moves on (StepBeat).
/// Core Animation's, on the render server; nothing with reduced motion.
struct Glint: NSViewRepresentable {
    /// When its step began: the light keeps the step's beat, the one its
    /// mark moves on (StepBeat), however often the line is laid out anew.
    var anchor: Date? = nil
    @Environment(\.accessibilityReduceMotion) private var still

    /// Words the light passes through rest under the ink, as a done step's
    /// do, so it has somewhere to take them.
    static let lit = Palette.ink.opacity(0.75)

    func makeNSView(context: Context) -> GlintView { GlintView() }
    func updateNSView(_ view: GlintView, context: Context) {
        view.anchor = anchor
        view.still = still
    }

    final class GlintView: NSView {
        private let band = CAGradientLayer()
        var still = false { didSet { if still != oldValue { restart() } } }
        var anchor: Date? { didSet { if anchor != oldValue { restart() } } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            layer?.addSublayer(band)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            restart()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            restart()
        }

        private func restart() {
            band.removeAllAnimations()
            let width = max(40, bounds.width * 0.6)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.frame = CGRect(x: -width, y: 0, width: width, height: bounds.height)
            var ink = NSColor.black
            effectiveAppearance.performAsCurrentDrawingAppearance { ink = Palette.NS.ink.usingColorSpace(.sRGB) ?? .black }
            band.colors = [ink.withAlphaComponent(0).cgColor, ink.cgColor, ink.withAlphaComponent(0).cgColor]
            CATransaction.commit()
            guard !still, bounds.width > 0 else { return }
            let pass = CAKeyframeAnimation(keyPath: "position.x")
            let from = -width / 2, to = bounds.width + width / 2
            pass.values = [from, from, to, to]
            pass.keyTimes = [0, 0.15, 0.4, 1]
            pass.duration = 4
            pass.repeatCount = .infinity
            pass.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
            if anchor != nil { pass.beginTime = StepBeat.begin(band, anchor: anchor) }
            band.add(pass, forKey: "glint")
        }
    }
}
