import QuartzCore
import SwiftUI

// A command's answer in the ⌘J field: at the head the command and the model it ran on (the model a
// menu: ⇧⌘R, the command again on another), then the command and the
// words it was given as your line, and the answer in full under it, a
// rewrite's changes marked. The
// field itself moves down to the foot for a follow-up (Omnibox), this
// head taking its place; beside it the pill says what Return does
// (Replace Selection over a field's text, Copy Response elsewhere) and
// ⌘K lists the rest (Browser.answerActions).
//
// Quiet on purpose, as the field is used many times a day: states swap
// without motion, words arrive as they are written, read ten times a
// second (SelectionCommands.ask). It watches the commands, never the
// agents, so a token on its way redraws only this.

struct FieldAnswer: View {
    let browser: Browser
    @ObservedObject var commands: SelectionCommands
    var height: CGFloat
    /// The answer's foot in view (FieldAnswer's scroll, as ChatTranscript's).
    @State private var atEnd = true
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
                .padding(.leading, 12) // design: the back chevron sits where the field's glass does, 12 from the edge
                .padding(.trailing, Omnibox.gutter)
                .frame(height: Omnibox.fieldHeight)
            ScrollViewReader { reader in
                ThreadScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        said
                        ForEach(commands.turns) { turn in
                            // Its Markdown read, as the answer showing reads it (rewrites stay literal).
                            Text(browser.answerIsRewrite ? AttributedString(turn.answer) : AgentAnswer.rich(turn.answer))
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let next = next(after: turn) { bubble(next) }
                        }
                        answer
                        sources
                        Color.clear.frame(height: 1).id(Self.end)
                            .onScrollVisibilityChange(threshold: 0.01) { atEnd = $0 }
                    }
                    .padding(.horizontal, Omnibox.gutter)
                    .padding(.top, 4)
                    // Its first words taking the live line's place, as the column's do.
                    // Only that way: a follow-up sent empties it, and the
                    // answer before folds to its lines at once.
                    .animation(still || commands.output.isEmpty ? nil : Motion.chatQuick, value: commands.output.isEmpty)
                }
                .scrollBounceBehavior(.basedOnSize)
                .edgeScroll()
                // Kept to its foot as the words come, as the column is.
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                // The head is where the field was: nothing floats over the top.
                .environment(\.underField, 0)
                // The newest words in view as they come, and a follow-up's
                // answer from its start: a jump, no scrolling motion, and
                // only when the foot is out of view (each scrollTo lays the
                // answer out at once).
                .onChange(of: commands.output) { _, _ in
                    if commands.stage == .running, !atEnd { reader.scrollTo(Self.end, anchor: .bottom) }
                }
            }
        }
        .frame(height: height, alignment: .top)
        // Where Open in Chat takes off from (ChatFlight).
        .background(FlightMark(kind: .answer, corner: Omnibox.corner))
        .onChange(of: commands.stage) { _, _ in browser.query.answerTurn += 1 }
        // The pill's Return words follow the row chosen under the answer.
        .onChange(of: commands.sourceSpot) { _, _ in browser.query.answerTurn += 1 }
        .onChange(of: commands.sources.count) { _, _ in browser.query.answerTurn += 1 }
        .onChange(of: commands.command?.executor) { _, _ in browser.query.answerTurn += 1 }
    }

    private static let end = "end"
    /// Where the model's name starts in the box: back, the command's mark,
    /// their gaps. The models' list drops from here (Omnibox).
    static let modelInset: CGFloat = 12 + 22 + 10 + Omnibox.tile + 10

    // MARK: the head

    /// Whose a model is, in one mark: its plan's (AgentPlan), or this Mac.
    static func mark(_ cli: String?) -> String { AgentPlan.of(cli)?.mark ?? "brand.apple.intelligence" }

    private var head: some View {
        HStack(spacing: 10) {
            Button { _ = browser.leavePlace() } label: {
                Symbol("chevron.left", size: 13)
                    .foregroundStyle(Palette.muted)
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .keyTip("Back")
            FieldMark(symbol: SelectionLayer.symbol(commands.command?.id ?? ""), tint: .systemPurple)
            VStack(alignment: .leading, spacing: 0) {
                Text(SelectionCommand.menuTitle(commands.command?.name ?? "Ask"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                model
            }
            Spacer(minLength: 8)
            // Top right, one mark: the chat in
            // full, the answer becoming the column (ChatFlight). Continue
            // as a Task stays in ⌘K's list.
            if commands.hasAgent {
                Button { browser.expandAnswer() } label: { Symbol("square.arrow.out", size: 14) }
                    .buttonStyle(.yab(.quiet, .regular, icon: .square))
                    .focusable(false)
                    .keyTip("Open in Chat")
            }
        }
    }

    /// Who answered: the model, and on a click (⇧⌘R too) the models to
    /// answer again on, in the field's own list; this Mac's model or none
    /// said in words.
    @ViewBuilder private var model: some View {
        let command = commands.command
        if AgentPlan.isPlan(command?.executor) || command?.executor == "mac" {
            Button { browser.chooseAnswerModel() } label: {
                HStack(spacing: 6) {
                    Symbol(FieldAnswer.mark(command?.executor), size: 10)
                    Text(command?.executor == "mac" ? "Apple Intelligence"
                         : AgentModels.find(command?.executor, command?.model)?.name ?? AgentModels.agentName(command?.executor ?? "claude"))
                        .lineLimit(1)
                    Symbol("chevron.up.chevron.down", size: 8, weight: .semibold) // design: MenuCell's own
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .keyTip("Answer again on another model", keys: Keymap.shared.text(.fieldAnswerModel))
        } else {
            Text("No model").font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }

    // MARK: what was said

    /// The command and the words it was given, as your line: words asked
    /// in the field as the column has them (SentWords), a command as its
    /// mark and name on the accent.
    @ViewBuilder private var said: some View {
        let words = commands.command?.id == "ask" && (commands.turns.isEmpty && commands.asked == nil || commands.snapshot?.text.isEmpty == true)
            ? commands.command?.prompt ?? "" : ""
        if !words.isEmpty {
            HStack {
                Spacer(minLength: 60)
                SentWords(words)
            }
        } else {
            command
        }
    }

    private var command: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Symbol(SelectionLayer.symbol(commands.command?.id ?? ""), size: 11)
                    // A question asked in the field is always its words:
                    // nothing selected stands for it.
                    Text(commands.command?.id == "ask" ? (commands.turns.isEmpty && commands.asked == nil || commands.snapshot?.text.isEmpty == true
                                                          ? commands.command?.prompt ?? "" : "Ask")
                         : SelectionCommand.menuTitle(commands.command?.name ?? ""))
                        .lineLimit(2)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.1), in: Capsule())
            }
        }
    }

    /// A follow-up, as your line: the column's (SentWords).
    private func bubble(_ words: String) -> some View {
        HStack {
            Spacer(minLength: 60)
            SentWords(words)
        }
    }

    /// What asked for the answer after this turn: the next turn's words,
    /// or the follow-up the answer showing is for.
    private func next(after turn: SelectionCommands.Turn) -> String? {
        guard let index = commands.turns.firstIndex(of: turn) else { return nil }
        return index + 1 < commands.turns.count ? commands.turns[index + 1].asked : commands.asked
    }

    // MARK: the answer

    @ViewBuilder private var answer: some View {
        switch commands.stage {
        case .running where commands.output.isEmpty:
            // The live line a chat's column has: the agent's face reading,
            // the light passing over its words.
            // Reading only when there is a selection to read: an Ask from
            // the field with nothing selected is thinking from the start.
            let reading = commands.turns.isEmpty && commands.snapshot?.text.isEmpty == false
            HStack(spacing: 8) {
                StepMark(art: reading ? .readPage : .think, live: true)
                MorphWords(reading ? "Reading the selection" : commands.lookingThrough.map { "Looking through " + $0 } ?? "Thinking")
                    .glint()
                    .foregroundStyle(Palette.muted)
            }
            .font(.system(size: 13.5))
            .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .offset(y: -6))))
        case .failed where commands.output.isEmpty:
            VStack(alignment: .leading, spacing: 4) {
                Text(commands.noChange ? "Nothing to change" : "Couldn\u{2019}t answer")
                    .font(.system(size: 13.5, weight: .semibold))
                if !commands.noChange {
                    Text(commands.error)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .textSelection(.enabled)
                } else {
                    Text("The text already reads as asked.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        case .closed:
            EmptyView()
        default:
            words
                .transition(.opacity)
            if browser.answerIsRewrite, commands.stage == .preview, !commands.showOriginal,
               let changes = FieldAnswerDiff.shared.marked(commands.snapshot?.text ?? "", commands.output).changes, changes > 0 {
                HStack(spacing: 6) {
                    Text(changes == 1 ? "1 change" : "\(changes) changes")
                    Text("·")
                    Text("hold")
                    KeyGlyphs(keys: "⌥", size: 12, tint: nil, rest: 0.6)
                    Text("for the original")
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            }
            if commands.stage == .failed, !commands.error.isEmpty {
                Text(commands.error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(ButtonCSS.danger)
            }
        }
    }

    /// The pages an Ask's answer came from, with the time you were there,
    /// over them the stretch of time; picking up, the thread to open again
    /// first. ↓ moves into them, ↩ opens the one chosen.
    @ViewBuilder private var sources: some View {
        if commands.stage == .preview, !commands.sources.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(commands.sourceCaption)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                ForEach(Array(commands.sources.enumerated()), id: \.element.id) { index, source in
                    AnswerSourceRow(source: source, chosen: commands.sourceSpot == index)
                        .contentShape(Rectangle())
                        .onTapGesture { browser.openSource(index) }
                        .padding(.horizontal, -8)
                }
            }
            .padding(.top, -2) // design: the rows sit close under the answer, as the column's sources do
        }
    }

    /// The answer's words: a rewrite with its changes marked (or the
    /// original, while ⌥ is held), anything else as the agent wrote it,
    /// its Markdown kept.
    @ViewBuilder private var words: some View {
        // Marked once it is all in: while it comes, the words as they are.
        if browser.answerIsRewrite, commands.stage != .running, let snap = commands.snapshot {
            if commands.showOriginal {
                Text(snap.text).font(.system(size: 15)).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(FieldAnswerDiff.shared.marked(snap.text, commands.output).text)
                    .font(.system(size: 15)).lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if browser.answerIsRewrite {
            Text(commands.output)
                .font(.system(size: 15)).lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Drawn as the chat's column draws its answers (ChatWords), a
            // size up for the field's width.
            // Each answer is new here: a lump of it is written out.
            ChatWords(text: commands.output, streaming: commands.stage == .running, size: 15, fresh: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A rewrite against what it rewrote, word by word: the new text with
/// what is new in it marked, and how many places changed. The last pair
/// is kept, so a redraw with the same words costs nothing.
@MainActor
final class FieldAnswerDiff {
    static let shared = FieldAnswerDiff()
    private var last: (key: String, value: (text: AttributedString, changes: Int?))?

    /// Past this many pieces (a word or the space after it) either side, no
    /// marks: the words as they are. About 600 words: the table is then
    /// under 6 MB and a few milliseconds, done once, as the answer lands.
    static let most = 1_200

    func marked(_ original: String, _ revised: String) -> (text: AttributedString, changes: Int?) {
        let key = original + "\u{0}" + revised
        if let last, last.key == key { return last.value }
        let value = Self.mark(original, revised)
        last = (key, value)
        return value
    }

    /// Words and the spaces between them, each its own piece, so the
    /// marked text reads exactly as written.
    static func pieces(_ text: String) -> [Substring] {
        var out: [Substring] = []
        var start = text.startIndex
        var inWord: Bool?
        for index in text.indices {
            let word = !text[index].isWhitespace
            if let was = inWord, was != word {
                out.append(text[start..<index])
                start = index
            }
            inWord = word
        }
        if start < text.endIndex { out.append(text[start...]) }
        return out
    }

    static func mark(_ original: String, _ revised: String) -> (text: AttributedString, changes: Int?) {
        let old = pieces(original)
        let new = pieces(revised)
        guard old.count <= most, new.count <= most else { return (AttributedString(revised), nil) }
        // The longest run the two have in common, piece by piece.
        let n = old.count, m = new.count
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var text = AttributedString()
        var changes = 0
        var inChange = false
        var i = 0, j = 0
        func add(_ piece: Substring, changed: Bool) {
            var part = AttributedString(String(piece))
            // Only words are marked: a space changed alone is no change to read.
            if changed, piece.contains(where: { !$0.isWhitespace }) {
                part.backgroundColor = Color.accentColor.opacity(0.16)
                part.underlineStyle = .single
                part.underlineColor = NSColor.controlAccentColor.withAlphaComponent(0.6)
                if !inChange { changes += 1 }
                inChange = true
            } else if !piece.allSatisfy(\.isWhitespace) {
                inChange = false
            }
            text += part
        }
        while j < m {
            if i < n, old[i] == new[j] {
                add(new[j], changed: false)
                i += 1; j += 1
            } else if i < n, table[i + 1][j] >= table[i][j + 1] {
                // A removed word marks where the change is, not a word to read.
                if old[i].contains(where: { !$0.isWhitespace }), !inChange { changes += 1; inChange = true }
                i += 1
            } else {
                add(new[j], changed: true)
                j += 1
            }
        }
        if i < n, old[i...].contains(where: { $0.contains(where: { !$0.isWhitespace }) }), !inChange { changes += 1 }
        return (text, changes)
    }
}

/// One page an answer came from: its mark, its title and where it is,
/// the time you were there; or the thread's folder, to open again.
struct AnswerSourceRow: View {
    let source: AnswerSource
    let chosen: Bool

    var body: some View {
        HStack(spacing: 10) {
            switch source.kind {
            case .folder:
                FieldMark(symbol: "folder")
            case .page:
                PlaceTileView(tile: .site(source.host), meter: AnswerSourceRow.meter)
            }
            (Text(source.title).foregroundStyle(Palette.ink)
             + Text(source.place.isEmpty ? "" : " · " + source.place).foregroundStyle(Palette.muted))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let at = source.at {
                Text(DayThreads.time(at))
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .font(.system(size: 13.5))
        .padding(.horizontal, 8)
        .frame(height: Omnibox.rowHeight)
        .background {
            if chosen { RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Omnibox.chosenFill) }
        }
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    /// A row's site mark watches no download.
    @MainActor static let meter = Hoard.Meter()
}

// MARK: - the field's side

extension Browser {
    /// A command picked in the field (or words of your own) answered there.
    func answer(_ command: SelectionCommand, on tab: Tab, snapshot: SelectionSnapshot) {
        query.acting = nil
        if !snapshot.text.isEmpty, command.id != "ask" || command.applyImmediately {
            close()
            selectionCommands.run(command, on: tab, snapshot: snapshot)
            return
        }
        query.answering = true
        selectionCommands.run(command, on: tab, snapshot: snapshot, inField: true)
        // The field empties for a follow-up, its rows gone.
        replaceTyped("")
    }

    /// Words asked in the field (its Ask row), answered in it as a
    /// command's are: the selection's place with nothing selected, the
    /// page ⌘L came up over being what they may be about, none in ⌘T's.
    /// Back gives the words again (leavePlace).
    func askInField(_ words: String) {
        guard !words.isEmpty else { return }
        if performFieldRequest(words) { return }
        guard Agents.ready else { close(); TaskLine.connect(); return }
        let tab = holder()
        // The words go up from the field into their line (SendFlight).
        SendFlight.takeOff(words, in: BrowserWindows.shared.window(for: self))
        let snap = SelectionSnapshot(asking: fresh || tab.isBlank || tab.shy ? nil : tab)
        fieldSelection = snap
        enterPlace(.selection)
        answer(SelectionCommand(id: "ask", name: "Ask", prompt: words, executor: "agent", custom: true), on: tab, snapshot: snap)
    }

    /// A direct user action must not be sent to the text-only answer session.
    /// Opening a page preserves the source tab's private browsing store.
    @discardableResult
    func performFieldRequest(_ words: String) -> Bool {
        if let url = TaskWords.openingURL(words) {
            let source = active
            selectionCommands.close()
            close()
            _ = open(url, foreground: true, from: source)
            return true
        }
        guard TaskWords.nativeRequest(words), let tab = active ?? tabs.first else { return false }
        selectionCommands.close()
        close()
        guard Agents.ready else { TaskLine.connect(); return true }
        Agents.shared.task(words, context: tab.shy ? [] : [.page(tab)], on: nil)
        return true
    }

    func followAnswer(_ words: String) {
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if performFieldRequest(words) { return }
        SendFlight.takeOff(words, in: BrowserWindows.shared.window(for: self))
        selectionCommands.stop()
        selectionCommands.follow(words)
        replaceTyped("")
    }

    /// Whether the answer showing is the selection rewritten, to be put
    /// back over it: its changes are marked, and Return replaces.
    var answerIsRewrite: Bool {
        let commands = selectionCommands
        guard let snap = commands.snapshot, let command = commands.command else { return false }
        if command.id == "ask" || command.result == "draft" { return false }
        return commands.canReplace(snap) && commands.turns.isEmpty && commands.asked == nil
    }

    /// What Return does under an answer, first, then the rest ⌘K lists.
    var answerActions: [FieldAction] {
        let commands = selectionCommands
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [FieldAction] = []
        // Words typed: they are sent, whatever the answer's state; one
        // still being written stops where it is, as a new question does.
        if !words.isEmpty {
            out.append(FieldAction(id: "follow", title: "Send Follow-up", symbol: "yab.send") {
                self.followAnswer(words)
            })
        }
        switch commands.stage {
        case .running:
            out.append(FieldAction(id: "stop", title: "Stop", symbol: "yab.stop") { self.selectionCommands.stop() })
        case .failed where commands.output.isEmpty:
            if commands.noChange {
                out.append(FieldAction(id: "back", title: "Back to Commands", symbol: "yab.chevleft") { self.leavePlace() })
            } else {
                out.append(FieldAction(id: "again", title: "Try Again", keys: Keymap.shared.text(.fieldAnswerAgain), symbol: "yab.reload") { self.againAnswer() })
            }
        case .preview, .failed:
            if commands.stage == .preview, let spot = commands.sourceSpot, commands.sources.indices.contains(spot) {
                let source = commands.sources[spot]
                out.append(FieldAction(id: "source", title: source.kind == .folder ? "Reopen as Folder" : "Open Page",
                                       symbol: source.kind == .folder ? "folder" : "arrow.up.right") { self.openSource(spot) })
            }
            out.append(FieldAction(id: "put", title: answerPrimary, symbol: answerPrimary == "Copy Response" ? "yab.copyframe.text" : "yab.text.right") {
                self.selectionCommands.handOver()
            })
            if answerPrimary != "Copy Response" {
                out.append(FieldAction(id: "copyanswer", title: "Copy Response", keys: Keymap.shared.text(.fieldAnswerCopy), symbol: "yab.copyframe.text") {
                    self.selectionCommands.copy()
                })
            }
            out.append(FieldAction(id: "again", title: "Again", keys: Keymap.shared.text(.fieldAnswerAgain), symbol: "arrow.clockwise", group: 1) { self.againAnswer() })
        case .closed:
            return out
        }
        if commands.stage != .running, AgentPlan.isPlan(commands.command?.executor) || commands.command?.executor == "mac" {
            out.append(FieldAction(id: "model", title: "Again with Another Model…", keys: Keymap.shared.text(.fieldAnswerModel), symbol: "yab.reload.spark", group: 1) {
                self.chooseAnswerModel()
            })
        }
        if commands.hasAgent {
            out.append(FieldAction(id: "chat", title: "Open in Chat", symbol: "square.arrow.out", group: 2) {
                self.expandAnswer()
            })
        }
        out.append(FieldAction(id: "task", title: "Continue as a Task", keys: Keymap.shared.text(.fieldAnswerTask), symbol: "agent.face", group: 2) {
            self.continueAnswerAsTask()
        })
        if commands.command?.id == "ask", commands.stage == .preview, let prompt = commands.command?.prompt {
            out.append(FieldAction(id: "keep", title: "Keep as a Command", symbol: "yab.cmd.plus", group: 2) {
                let name = prompt.split(separator: " ").prefix(4).joined(separator: " ")
                self.selectionCommands.keepCurrent(as: name)
                self.toaster.pop("Kept in Commands", mark: "checkmark", feedback: .success)
            })
        } else if commands.command?.id != "ask" {
            out.append(FieldAction(id: "editcommand", title: "Edit Command", symbol: "pencil", group: 2) {
                self.close()
                SettingsWindow.shared.showCommands(for: self)
            })
        }
        return out
    }

    /// What Return puts the answer to, in the command's own words.
    private var answerPrimary: String {
        let commands = selectionCommands
        if commands.command?.result == "draft" { return "Insert in Reply" }
        if let snap = commands.snapshot, answerIsRewrite || (commands.canReplace(snap) && commands.command?.id != "ask") {
            return "Replace Selection"
        }
        return "Copy Response"
    }

    /// The command again, as it ran: a follow-up's history goes with it.
    func againAnswer() {
        let commands = selectionCommands
        guard let command = commands.command else { return }
        commands.turns = []
        commands.asked = nil
        commands.run(command)
    }

    /// The answer, and what asked for it, handed to your agent as a task
    /// in this tab, with the selection: the field goes.
    /// Open in Chat: the answer's chat into the column, the agent left at
    /// work. The card it was in, the field's or the one over the page,
    /// becomes the column in one motion (ChatFlight).
    func expandAnswer(waited: Int = 0) {
        // Its agent's session begins a moment after the command: until
        // then, looked for again, a beat at a time.
        guard selectionCommands.hasChat else {
            if selectionCommands.hasAgent, waited < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.expandAnswer(waited: waited + 1) }
            }
            return
        }
        let takeoff = ChatFlight.takeOff()
        let inField = selectionCommands.answering
        guard let id = selectionCommands.handOff() else { return }
        if let takeoff, let landing = ChatFlight.landing(in: takeoff.window, width: ChatLook.width, leading: chatLeads) {
            ChatFlight.fly(takeoff, to: landing, corner: Radius.surface)
            // The plate on screen over the card and flying now, before the
            // card is put away and the column built under it: that pass
            // is the heavy one, and the render server flies it meanwhile.
            CATransaction.flush()
        }
        if inField { close() } else { selectionCommands.close() }
        showChat(id)
    }

    func continueAnswerAsTask() {
        let commands = selectionCommands
        guard let snap = commands.snapshot, let tab = active else { return }
        var words = commands.asked ?? commands.command.map { $0.id == "ask" ? $0.prompt : SelectionCommand.menuTitle($0.name) } ?? ""
        // A question asked in the field had nothing selected: about the
        // page it came up over, or, from ⌘T, in tabs of its own.
        let asked = snap.text.isEmpty
        if !commands.output.isEmpty {
            words += (asked ? "\n\nWhat was answered so far:\n" : "\n\nWhat was answered so far, about the selected text:\n") + commands.output
        }
        close()
        guard Agents.ready else { TaskLine.connect(); return }
        if asked, snap.url.isEmpty {
            if let session = Agents.shared.task(words, context: [], on: nil) { showChat(session.id) }
        } else {
            let context = asked ? [TaskContext.page(tab)] : [TaskContext(kind: .selection, title: "Selection", url: tab.address, tab: tab.id, text: snap.text)]
            Agents.shared.task(words, context: context, on: tab)
        }
    }

    /// ⇧⌘R, or the model under the answer's name: the model picker in the
    /// middle of the window (ModelPicker), on the model that answered,
    /// this Mac's model offered when the words fit it.
    func chooseAnswerModel() {
        let commands = selectionCommands
        let command = commands.command
        let fits = FormModel.ready && (commands.snapshot?.text.count ?? 0) <= SelectionCommands.macLimit
        withAnimation(Motion.chatQuick) {
            modelPicker = ModelPickerRequest(
                title: "Answer Again On", clis: AgentPlan.clis.filter(AgentModels.here), offersMac: fits,
                choice: ModelChoice(cli: command?.executor, model: command?.model, effort: command?.effort)
            ) { choice in commands.again(with: choice) }
        }
    }

    var answerModels: [FieldAction] {
        let commands = selectionCommands
        let command = commands.command
        let hidden = ModelDefaults.shared.hidden
        var models: [AgentModel] = []
        if FormModel.ready, (commands.snapshot?.text.count ?? 0) <= SelectionCommands.macLimit { models.append(AgentModels.mac) }
        for plan in AgentPlan.all where AgentModels.here(plan.cli) {
            models += plan.models.filter { !hidden.contains($0.id) }
        }
        return models.map { model in
            let now = model.cli == command?.executor && (model.cli == "mac" || model.model == (command?.model ?? ""))
            return FieldAction(id: "model-" + model.id, title: (model.cli == "mac" ? "Apple Intelligence" : model.name) + (now ? " (this one)" : ""),
                               // Marks, not the apps' icons: looked up in the
                               // list, the icon hung the app (LaunchServices).
                               symbol: FieldAnswer.mark(model.cli),
                               group: model.cli == "mac" ? 0 : 1 + (AgentPlan.clis.firstIndex(of: model.cli) ?? AgentPlan.all.count)) {
                self.query.choosingModel = false
                self.query.acting = nil
                self.selectionCommands.again(with: ModelChoice(cli: model.cli, model: model.model.isEmpty ? nil : model.model))
            }
        }
    }

    /// Keys under an answer: ⌘R again, ⇧⌘R on another model, ⌘↩ as a
    /// task, ⇧⌘C copies the answer. True when taken.
    func answerKey(_ event: NSEvent) -> Bool {
        guard query.answering, query.acting == nil else { return false }
        // ↓ into the rows under the answer, ↑ back out of them.
        let commands = selectionCommands
        if [125, 126].contains(event.keyCode), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           typed.isEmpty, commands.stage == .preview, !commands.sources.isEmpty {
            let last = commands.sources.count - 1
            if event.keyCode == 125 {
                commands.sourceSpot = min(last, (commands.sourceSpot ?? -1) + 1)
                return true
            }
            guard let spot = commands.sourceSpot else { return false }
            commands.sourceSpot = spot == 0 ? nil : spot - 1
            return true
        }
        let map = Keymap.shared
        if map.matches(event, .fieldAnswerAgain) { return runAction("again") }
        if map.matches(event, .fieldAnswerModel) { return runAction("model") }
        if map.matches(event, .fieldAnswerCopy) { return runAction("copyanswer") || runAction("put") }
        if map.matches(event, .fieldAnswerTask) { return runAction("task") }
        return false
    }
}
