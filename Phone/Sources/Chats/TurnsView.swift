import SwiftUI
import UIKit

/// A chat's turns, newest at the bottom: the question bubbles, the answers
/// (signed by the iPhone in the full chat), Claude's typing dots, quiet
/// notes, a pick from a list checked on many sites, and a task's steps in
/// words with its tabs on the Mac.
struct TurnsView: View, Equatable {
    let chat: Chat
    /// The full chat: answers from the iPhone are signed under them.
    let full: Bool
    let arrival: Arrival?
    /// The bubble words are flying into, hidden until they land.
    let flyingInto: Int?
    let task: TaskTurns?
    /// Out of sight, for measuring: nothing moves (the typing dots stand still).
    var still = false
    /// A question's ink bubble in the card, by its index among the questions.
    var onBubble: (Int, CGRect) -> Void = { _, _ in }

    struct TaskTurns: Equatable {
        var definition: TaskDefinition
        var run: TaskRun?
        /// When the Mac went to sleep, for a task waiting for it.
        var macAsleepSince: String?
    }

    /// Answers that came in place of the typing bubble while on screen.
    @State private var seen = Seen()

    private typealias C = Metrics.Chat

    var body: some View {
        let fresh = still ? [] : seen.fresh(chat)
        let list = turns
        VStack(alignment: .leading, spacing: task == nil ? 0 : 12) {
            if let task {
                TaskTurnsView(task: task)
            } else {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, turn in
                    turnView(turn, next: list[safe: index + 1]?.message, arriving: arriving(index), fresh: fresh.contains(index))
                        .padding(.top, index == 0 ? 0 : Self.gap(after: list[index - 1].message.role, before: turn.message.role))
                        // Named states hold an arrival at a given point (the
                        // section "Frame by frame"); live, each turn rises in itself.
                        .opacity(Motion.disabled && arriving(index) ? (arrival?.shown ?? 1) : 1)
                        .offset(y: Motion.disabled && arriving(index) ? (1 - (arrival?.shown ?? 1)) * 6 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Only the turns themselves say whether they draw again: a chat renamed,
    /// pinned or marked unread leaves a long transcript as it was (its
    /// title is in the head, not here). The bubble callback is the same work.
    static func == (a: TurnsView, b: TurnsView) -> Bool {
        a.chat.id == b.chat.id && a.chat.messages == b.chat.messages && a.full == b.full && a.arrival == b.arrival
            && a.flyingInto == b.flyingInto && a.task == b.task && a.still == b.still
    }

    private struct Turn {
        var message: Message
        /// Its index among the questions, for bubbles.
        var question: Int?
        /// Its place; the typing bubble at the foot keeps one of its own, so
        /// words coming in above it put it lower, not out and in again.
        var id: Int
    }

    private var turns: [Turn] {
        var n = 0
        let messages = chat.messages
        return messages.enumerated().map { index, message in
            let id = message.role == .typing && index == messages.count - 1 ? -1 : index
            guard message.role == .you else { return Turn(message: message, id: id) }
            defer { n += 1 }
            return Turn(message: message, question: n, id: id)
        }
    }

    /// Where the typing bubble stood at the last look: an answer there now
    /// came just now, its words written out and grown in (the Mac's
    /// `arriving`); one there when the chat was opened stands as it is.
    final class Seen {
        private var chat: Chat.ID?
        private var typing: Set<Int> = []
        private var arrived: Set<Int> = []

        func fresh(_ chat: Chat) -> Set<Int> {
            if chat.id != self.chat {
                self.chat = chat.id
                typing = []
                arrived = []
            }
            for (index, message) in chat.messages.enumerated() where message.role == .answer && typing.contains(index) {
                arrived.insert(index)
            }
            typing = Set(chat.messages.indices.filter { chat.messages[$0].role == .typing || chat.messages[$0].role == .wait })
            return arrived
        }
    }

    /// Messages' rhythm: 2 inside a run from one side, 10 when the other
    /// side speaks; a status line stands just under its bubble's tail.
    static func gap(after previous: Message.Role, before role: Message.Role) -> CGFloat {
        typealias C = Metrics.Chat
        func side(_ role: Message.Role) -> Int? {
            switch role {
            case .you: 0
            case .answer, .typing: 1
            default: nil
            }
        }
        if role == .wait || role == .failed { return previous == .you ? C.statusGap : C.turnGap }
        if let a = side(previous), a == side(role) { return C.runGap }
        return C.turnGap
    }

    private func arriving(_ index: Int) -> Bool {
        guard let arrival else { return false }
        return index >= arrival.from && chat.messages[index].role != .you
    }

    @ViewBuilder
    private func turnView(_ turn: Turn, next: Message?, arriving: Bool, fresh: Bool) -> some View {
        let message = turn.message
        let rise = Arrive(active: arriving && !Motion.disabled)
        let arrived = (fresh || arriving) && !still && !Motion.disabled
        switch message.role {
        case .you:
            // Only the last of a run has the tail; one not sent has Messages' red ! beside it.
            let tail = next?.role != .you
            let failed = next?.role == .failed ? next : nil
            HStack(spacing: C.failedGap) {
                VStack(alignment: .trailing, spacing: C.runGap) {
                    // A row of Now handed over on the Mac, over its "Do It".
                    if let handed = message.handed { HandedCard(handed: handed) }
                    // Photos and files sent with the words, over them.
                    if !message.files.isEmpty { SentFiles(files: message.files) }
                    if !message.text.isEmpty {
                        // The ink's own frame: words sent fly into exactly it.
                        QuestionBubble(text: message.text, tail: tail)
                            .messageHold(message, shape: MessageBubble(mine: true, tail: tail), enabled: !still)
                            .opacity(turn.question == flyingInto ? 0 : 1)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatSpace.card)) } action: { frame in
                                if let q = turn.question { onBubble(q, frame) }
                            }
                    }
                }
                if let failed { NotSentMark(question: message.text, reason: failed.text, chat: chat.id, still: still) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .answer:
            VStack(alignment: .leading, spacing: 0) {
                // Only the last of a run has the tail, the agent's as yours.
                if !message.text.isEmpty || message.cards.isEmpty {
                    AnswerWords(text: message.text, chat: chat.id, streaming: chat.messages.last?.role == .typing
                                && message == chat.messages.last(where: { $0.role == .answer }), fresh: arrived,
                                tail: next?.role != .answer)
                        // Lifted on its card, the words alone: a bubble in a card is two grounds.
                        .messageHold(message, lifted: AnswerWords(text: message.text, chat: chat.id, bubbles: false), enabled: !still)
                }
                // What its turn made on the Mac, a card each, under the words.
                if !message.cards.isEmpty {
                    ResultCardsView(cards: message.cards)
                        .padding(.top, message.text.isEmpty ? 0 : 8)
                }
                // Nothing under an answer, as in Messages: Copy, Ask Again and
                // its steps are in the bubble's held menu (MessageHold), and
                // who answered is said in the head.
                if full, let work = message.work, work.kind != .actions { TurnWorkView(work: work, chat: chat, still: still) }
            }
            .transition(arrived ? ChatArrival.message : .identity)
        case .pick:
            if let pick = message.pick {
                PickView(pick: pick, chat: chat.id).messageHold(message, lifted: PickView(pick: pick, chat: chat.id), enabled: !still).modifier(rise)
            }
        case .note:
            ChatNote(text: message.text, glyph: nil).modifier(rise)
        case .wait:
            // Under the question, as Messages' Delivered: the words, never a lone mark.
            MacWaitRow(message: message).modifier(rise)
        case .failed:
            if message.mac?.expired == true, let question = chat.messages.last(where: { $0.role == .you })?.text {
                ExpiredRow(question: question, mac: message.mac?.name ?? "your Mac")
                    .padding(.trailing, C.failedMark + C.failedGap)
                    .modifier(rise)
            } else {
                MessageStatus(text: "Not Sent", failed: true)
                    .padding(.trailing, C.failedMark + C.failedGap)
                    .modifier(rise)
            }
        case .typing:
            TypingDots(by: message.by ?? .claude, agent: chat.macAgentName ?? SettingsStore.shared.agent.name, still: still)
                .transition(still ? .identity : ChatArrival.typing)
        case .work:
            if let work = message.work { TurnWorkView(work: work, chat: chat, still: still).modifier(rise) }
        }
    }
}

/// A turn coming in: it fades in and rises 6 points as it appears, a little
/// after the sheet has made room for it (Motion.answerWords).
struct Arrive: ViewModifier {
    let active: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        let hidden = active && !shown
        content
            .opacity(hidden ? 0 : 1)
            .offset(y: hidden ? 6 : 0)
            .onAppear {
                guard active, !shown else { return }
                Motion.answerWords.run { shown = true }
            }
    }
}

/// The coordinate space of the card's laid-out words.
enum ChatSpace {
    static let card = "chat.card"
    static let list = "chat.list"
}

/// What the person asked, as Messages draws it and as the Mac's chat column
/// does: white words on the accent, its tail at the foot toward them. Laid
/// out as the prototype's CSS block: one line hugs its words; once they
/// wrap, the bubble takes its whole 290, the tail's room in it (BubbleLayout).
struct QuestionBubble: View {
    let text: String
    var tail = true

    private typealias C = Metrics.Chat

    var body: some View {
        let layout = BubbleLayout(text)
        Text(layout.text)
            .font(.system(size: C.text))
            .foregroundStyle(.white)
            .cssLineHeight(C.bubbleLineHeight, size: C.text)
            .frame(width: layout.wraps ? layout.inner : nil, alignment: .leading)
            .fixedSize(horizontal: !layout.wraps, vertical: true)
            .padding(C.bubblePadding)
            .background(MessageBubble(mine: true, tail: tail).fill(Color.accentColor))
            .accessibilityLabel(text)
            .accessibilityIdentifier("chat.question")
    }
}

/// A question's lines and size, as CSS lays out the prototype's bubble:
/// lines break greedily, each word on the first line it fits (SwiftUI's own
/// breaking pushes a word down to spare an orphan, CSS doesn't); a single
/// line hugs its words, wrapped lines take the whole 290. The flying words
/// land on exactly this rect.
struct BubbleLayout {
    let lines: [String]
    let width: CGFloat
    let wraps: Bool

    private typealias C = Metrics.Chat

    /// The words' room inside the bubble's padding and its tail's room.
    var inner: CGFloat { BubbleLayout.room }
    static var room: CGFloat { C.bubbleMaxWidth - C.bubblePadding.leading - C.bubblePadding.trailing - C.tailRoom }
    var text: String { lines.joined(separator: "\n") }
    var size: CGSize {
        CGSize(width: width,
               height: CGFloat(lines.count) * C.text * C.bubbleLineHeight + C.bubblePadding.top + C.bubblePadding.bottom)
    }


    init(_ text: String) {
        let room = BubbleLayout.room
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var lines: [String] = []
        var line = ""
        for word in words {
            let candidate = line.isEmpty ? word : line + " " + word
            // Half a point of slack: never a line SwiftUI would wrap again.
            if line.isEmpty || Markup.width(candidate, size: C.text) <= room - 0.5 {
                line = candidate
            } else {
                lines.append(line)
                line = word
            }
        }
        lines.append(line)
        self.lines = lines
        wraps = lines.count > 1
        let one = Markup.width(lines[0], size: C.text).rounded(.up)
        width = wraps ? C.bubbleMaxWidth : min(C.bubbleMaxWidth, one + C.bubblePadding.leading + C.bubblePadding.trailing + C.tailRoom)
    }
}

/// An answer's words, each paragraph a gray bubble of its own, as the
/// Mac's chat column says them. Words that came just now in one lump are
/// written out (WriteOut), words still coming soak in (FreshWords); words
/// read again later stand at once.
struct AnswerWords: View {
    let text: String
    let chat: Chat.ID
    var streaming = false
    /// In bubbles: not a pick's reasons, which stand under its head.
    var bubbles = true
    /// Only the last of a run has the tail (ChatMarkdownContent).
    var tail = true
    @State private var out: WriteOut?

    init(text: String, chat: Chat.ID, streaming: Bool = false, fresh: Bool = false, bubbles: Bool = true, tail: Bool = true) {
        self.text = text
        self.chat = chat
        self.streaming = streaming
        self.bubbles = bubbles
        self.tail = tail
        let lump = fresh && !Motion.disabled && text.count > WriteOut.lump
        _out = State(initialValue: lump ? WriteOut(from: 0, to: text.count, start: Date()) : nil)
    }

    var body: some View {
        // Ticks only while a lump is being written out.
        TimelineView(.animation(minimumInterval: WriteOut.tick, paused: out == nil)) { context in
            let shown = out.map { String(text[..<WriteOut.stop(text, at: $0.count(at: context.date))]) } ?? text
            let writing = streaming || out != nil
            ChatMarkdownView(text: shown, chat: chat, streaming: writing, bubbles: bubbles, fresh: writing, tail: tail)
        }
        .onChange(of: text) { old, new in
            guard !Motion.disabled else { out = nil; return }
            let now = Date()
            if let going = out {
                let at = going.count(at: now)
                out = new.count > at ? WriteOut(from: at, to: new.count, start: now) : nil
            } else if new.count - old.count > WriteOut.lump, new.hasPrefix(old) {
                // A lump more of the same words, not the same words drawn anew.
                out = WriteOut(from: old.count, to: new.count, start: now)
            }
        }
        // Written out: the words stand as any others.
        .task(id: out) {
            guard let end = out?.end else { return }
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            if !Task.isCancelled { out = nil }
        }
        // Held anywhere beside its bubbles, it lifts with its menu too.
        .contentShape(Rectangle())
        // One element holding the blocks: an identifier on the bare stack
        // went onto every element inside it, over their own ("chat.code",
        // "chat.table"), and those never reached XCTest or VoiceOver tools.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.answer")
    }
}

/// What became of a question, under it at the right in Messages' small
/// gray: "Waits for your Mac"; one not sent says "Not Sent" in red.
struct MessageStatus: View {
    let text: String
    let failed: Bool

    var body: some View {
        Text(text)
            .font(.system(size: Metrics.Chat.statusFont, weight: .medium))
            .foregroundStyle(failed ? Color.red : ChatInk.gray(0.6))
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
            .padding(.trailing, 4)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier(failed ? "chat.notSent" : "chat.status")
    }
}

/// Messages' red ! beside a question that wasn't sent: a tap says why and
/// offers Try Again, which sends its words again.
struct NotSentMark: View {
    @Environment(AppModel.self) private var app
    let question: String
    let reason: String
    let chat: Chat.ID
    var still = false

    var body: some View {
        Menu {
            Section(reason) {
                Button { tryAgain() } label: {
                    Label { Text("Try Again") } icon: {
                        UIImage.menuGlyph(MacGlyph.yabReload).map { Image(uiImage: $0) } ?? Image(systemName: "arrow.clockwise")
                    }
                }
            }
        } label: {
            Text("!")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: Metrics.Chat.failedMark, height: Metrics.Chat.failedMark)
                .background(Color.red, in: Circle())
                .frame(minWidth: Metrics.touch, minHeight: Metrics.touch)
                .contentShape(Rectangle())
                .padding(.horizontal, -(Metrics.touch - Metrics.Chat.failedMark) / 2)
        }
        .disabled(still)
        .accessibilityLabel("Not Sent")
        .accessibilityHint(reason)
        .accessibilityIdentifier("chat.tryAgain")
    }

    private func tryAgain() {
        guard app.chatSheet.chatID == chat else { return }
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        DispatchQueue.main.async { app.send(question) }
    }
}

/// A quiet centered line: Claude carries on; the answer waits for the Mac.
struct ChatNote: View {
    let text: String
    let glyph: GlyphName?

    var body: some View {
        HStack(spacing: 6) {
            if let glyph {
                Glyph(glyph, size: 15, color: ChatInk.gray(0.6))
            } else {
                AgentFace(size: 13, color: ChatInk.gray(0.6), lineWidth: 2.4)
            }
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(ChatInk.gray(0.6))
                .cssLineHeight(1.3, size: 12.5, weight: .medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.note")
    }
}

/// An answer coming: three dots in the agent's gray bubble, its tail two
/// drops at its foot, as Messages draws it and as the Mac's chat column
/// does (ChatTyping); who it is in words for VoiceOver.
struct TypingDots: View {
    var by: Chat.Answerer = .claude
    /// Who answers on the Mac, for VoiceOver: "Claude" or "ChatGPT".
    var agent = "Claude"
    var still = false

    private typealias C = Metrics.Chat

    var body: some View {
        TypingBeat(still: still || Motion.disabled || Motion.reduced)
            .frame(width: C.typingPitch * 2 + C.typingDot, height: C.typingDot)
            .frame(width: C.typingSize.width, height: C.typingSize.height)
            .background {
                Capsule().fill(ChatInk.agentBubble)
                    .overlay(alignment: .bottomLeading) {
                        Circle().fill(ChatInk.agentBubble)
                            .frame(width: C.typingDrop, height: C.typingDrop)
                            .offset(C.typingDropAt)
                        Circle().fill(ChatInk.agentBubble)
                            .frame(width: C.typingDrip, height: C.typingDrip)
                            .offset(C.typingDripAt)
                    }
            }
            .padding(.leading, C.tailRoom)
            .padding(.bottom, C.typingFoot)
            .accessibilityElement()
            .accessibilityLabel(by == .iphone ? "Apple Intelligence is answering" : "\(agent) is answering")
            .accessibilityIdentifier("chat.typing")
    }
}

/// The dots' beat on their own layers, as the Mac's: off SwiftUI's update
/// loop, already in phase as they arrive. Brighter, a little bigger and a
/// point up at 30 % of the beat, each dot a fifth of a second after the one
/// before; standing still, they rest a little brighter.
private struct TypingBeat: UIViewRepresentable {
    let still: Bool

    func makeUIView(context: Context) -> DotsView { DotsView() }
    func updateUIView(_ view: DotsView, context: Context) { view.still = still }
    static func dismantleUIView(_ view: DotsView, coordinator: ()) { view.stop() }

    final class DotsView: UIView {
        private typealias C = Metrics.Chat
        private let dots = (0..<3).map { _ in CALayer() }
        /// Resting, at the top of the beat, and standing still.
        private static let rest: Float = 0.35
        private static let lit: Float = 1
        private static let held: Float = 0.7
        private static let keyTimes: [NSNumber] = [0, 0.3, 0.6, 1]
        var still = false { didSet { if still != oldValue { refresh() } } }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            for dot in dots { layer.addSublayer(dot) }
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: DotsView, _: UITraitCollection) in
                view.refresh()
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            refresh()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            refresh()
        }

        func stop() { dots.forEach { $0.removeAllAnimations() } }

        private func refresh() {
            let ink = ChatInk.agentUI.resolvedColor(with: traitCollection).withAlphaComponent(ChatInk.typingDots)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, dot) in dots.enumerated() {
                dot.frame = CGRect(x: CGFloat(index) * C.typingPitch, y: (bounds.height - C.typingDot) / 2,
                                   width: C.typingDot, height: C.typingDot)
                dot.cornerRadius = C.typingDot / 2
                dot.backgroundColor = ink.cgColor
                dot.opacity = still ? Self.held : Self.rest
            }
            CATransaction.commit()
            guard !still, window != nil, bounds.width > 0 else { stop(); return }
            for (index, dot) in dots.enumerated() where dot.animation(forKey: "typing") == nil {
                let opacity = CAKeyframeAnimation(keyPath: "opacity")
                opacity.values = [Self.rest, Self.lit, Self.rest, Self.rest]
                let scale = CAKeyframeAnimation(keyPath: "transform.scale")
                scale.values = [1, C.typingSwell, 1, 1]
                let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
                rise.values = [0, -C.typingRise, 0, 0]
                for animation in [opacity, scale, rise] {
                    animation.keyTimes = Self.keyTimes
                    animation.duration = Motion.typingBeat
                    animation.timingFunctions = (0..<3).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
                }
                let pulse = CAAnimationGroup()
                pulse.animations = [opacity, scale, rise]
                pulse.duration = Motion.typingBeat
                // Already in phase on arrival, rather than all three at rest
                // waiting for their first beat.
                pulse.beginTime = dot.convertTime(CACurrentMediaTime(), from: nil) - Motion.typingBeat + Double(index) * Motion.typingStagger
                pulse.repeatCount = .infinity
                // Kept while the app is away: a beat that never ends.
                pulse.isRemovedOnCompletion = false
                dot.add(pulse, forKey: "typing")
            }
        }
    }
}

/// The best of a list checked on many sites: its name, why, the table of
/// what was found (the first row tinted), and what was skipped.
struct PickView: View {
    let pick: Message.Pick
    let chat: Chat.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pick.head)
                .font(.system(size: 19, weight: .bold))
                .em(-0.02, size: 19)
                .foregroundStyle(Ink.primary)
                .cssLineHeight(1.2, size: 19, weight: .bold)
            AnswerWords(text: pick.why, chat: chat, bubbles: false)
            table
            Text(pick.foot)
                .font(.system(size: 12.5))
                .foregroundStyle(ChatInk.gray(0.6))
                .cssLineHeight(1.3, size: 12.5)
        }
        .accessibilityIdentifier("chat.pick")
    }

    /// Columns as wide as CSS's auto table layout makes them: each its widest
    /// cell, the room left shared out in proportion.
    private var table: some View {
        GeometryReader { geo in
            let widths = columns(width: geo.size.width)
            VStack(spacing: 0) {
                ForEach(Array(pick.rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            Text(cell)
                                .font(.system(size: 13.5, weight: column == 0 ? .semibold : .regular))
                                .foregroundStyle(column == row.count - 1 ? ChatInk.gray(0.62) : Ink.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .frame(width: widths[safe: column] ?? 0, alignment: column == row.count - 1 ? .trailing : .leading)
                        }
                    }
                    .frame(height: 32.5)
                    .background(index == 0 ? ChatInk.fill(0.08) : .clear)
                    .overlay(alignment: .top) { Rectangle().fill(ChatInk.gray(0.16)).frame(height: 0.5) }
                }
            }
        }
        .frame(height: CGFloat(pick.rows.count) * 32.5)
    }

    private func columns(width: CGFloat) -> [CGFloat] {
        let count = pick.rows.map(\.count).max() ?? 0
        var natural = [CGFloat](repeating: 0, count: count)
        for row in pick.rows {
            for (i, cell) in row.enumerated() {
                natural[i] = max(natural[i], Markup.width(cell, size: 13.5, weight: i == 0 ? .semibold : .regular) + 12)
            }
        }
        let sum = natural.reduce(0, +)
        guard sum > 0 else { return natural }
        let extra = max(0, width - sum)
        return natural.map { $0 + extra * $0 / sum }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// A task's chat: the ask, its steps in words, what it waits for, its tabs
/// in a folder on the Mac, and the result when done.
struct TaskTurnsView: View {
    let task: TurnsView.TaskTurns

    private var def: TaskDefinition { task.definition }
    private var status: TaskStatus { task.run?.status ?? .done }
    private var step: Int { min(task.run?.step ?? def.steps.count - 1, max(0, def.steps.count - 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuestionBubble(text: def.ask)
                .frame(maxWidth: .infinity, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<(def.steps.isEmpty ? 0 : step + 1), id: \.self) { i in
                    stepRow(i)
                }
                waitRow
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Its tabs, in a folder on your Mac")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChatInk.gray(0.62))
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(def.tabs.prefix(max(1, min(def.tabs.count, step + 1))).enumerated()), id: \.offset) { _, tab in
                        thumb(tab)
                    }
                }
            }
            if status == .done {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Done").font(.system(size: 13, weight: .semibold)).foregroundStyle(ChatInk.gray(0.62))
                    Text(Markup.attributed(def.resultLong ?? def.result, size: 15))
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.primary)
                        .cssLineHeight(1.45, size: 15)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TaskInk.doneGround, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var live: Bool { status == .running || status == .sending }

    private func stepRow(_ i: Int) -> some View {
        let s = def.steps[i]
        let on = live && i == step
        return HStack(spacing: 10) {
            Favicon(icon: s.icon, size: 18)
            Text(on ? s.run : s.done)
                .font(.system(size: 15, weight: on ? .medium : .regular))
                .foregroundStyle(on ? Ink.primary : ChatInk.step)
                .frame(maxWidth: .infinity, alignment: .leading)
            if on {
                PulsingDot().padding(.trailing, 4)
            } else {
                Glyph(.checkmark1Small, size: 16, color: ChatInk.tick)
            }
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.step")
    }

    @ViewBuilder
    private var waitRow: some View {
        switch status {
        case .code:
            needs(.key1, "Waiting for the code \(codeSender) sent to this \(DeviceWord.name)")
        case .yes:
            needs(.creditCard1, "Waiting for you: \((def.yes ?? "your yes").replacingOccurrences(of: "?", with: ""))")
        case .failed:
            HStack(spacing: 10) {
                Glyph(.exclamationCircle, size: 18, color: ChatInk.needs)
                Text((def.failure ?? "It stopped").replacingOccurrences(of: " \u{00B7} ", with: ": ") + " on your Mac")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(ChatInk.needs)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 36)
        case .waits:
            HStack(spacing: 10) {
                Glyph(.macbook, size: 18, color: TaskInk.quiet)
                Text(TaskTurnsView.waitWords(since: task.macAsleepSince))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(ChatInk.needs)
            }
            .frame(minHeight: 36)
        default:
            EmptyView()
        }
    }

    /// A task waiting for the Mac, when it went to sleep if known.
    static func waitWords(since: String?) -> String {
        let asleep = since.map { "asleep since \($0)" } ?? "asleep"
        return "Waits for your Mac \u{00B7} \(asleep). It starts when the Mac wakes."
    }

    private var codeSender: String {
        guard let code = def.code, let range = code.range(of: #"code (.+) sent"#, options: .regularExpression) else { return "the site" }
        return String(code[range].dropFirst(5).dropLast(5))
    }

    private func needs(_ glyph: GlyphName, _ words: String) -> some View {
        HStack(spacing: 10) {
            Glyph(glyph, size: 18, color: ChatInk.needs)
            Text(words).font(.system(size: 15, weight: .semibold)).foregroundStyle(ChatInk.needs)
        }
        .frame(minHeight: 36)
    }

    /// A sketch of a tab the task opened on the Mac: lines for a list, a
    /// strip of seats for a seat map.
    private func thumb(_ tab: TaskDefinition.TaskTab) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 5) {
                if tab.icon == "google" {
                    ForEach(0..<3, id: \.self) { _ in line(8) }
                } else {
                    HStack(spacing: 4) {
                        ForEach(0..<6, id: \.self) { _ in RoundedRectangle(cornerRadius: 2).fill(TaskInk.thumbInk) }
                    }
                    .frame(height: 30)
                    line(8)
                }
            }
            .padding(8)
            .frame(width: 112, height: 72, alignment: .topLeading)
            .background(TaskInk.thumbGround, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Ink.outline.opacity(0.08), lineWidth: 0.5))
            HStack(spacing: 5) {
                Favicon(icon: tab.icon, size: 14)
                Text(tab.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ChatInk.gray(0.75))
                    .lineLimit(1)
                    .fixedSize()
            }
            // Cut at the thumbnail's edge, no ellipsis, as the prototype's overflow.
            .frame(width: 112, alignment: .leading)
            .clipped()
        }
    }

    private func line(_ height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(TaskInk.thumbInk).frame(height: height)
    }
}

/// The live step's dot, beating once a second.
struct PulsingDot: View {
    var body: some View {
        Group {
            if Motion.disabled || Motion.reduced {
                Circle().fill(Ink.primary).frame(width: 8, height: 8)
            } else {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                    let k = 0.5 - 0.5 * cos(phase * 2 * .pi)
                    Circle().fill(Ink.primary).frame(width: 8, height: 8).opacity(1 - 0.5 * k).scaleEffect(1 - 0.15 * k)
                }
            }
        }
        .frame(width: 8, height: 8)
    }
}
