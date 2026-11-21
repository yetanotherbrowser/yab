import AppKit
import Combine
@preconcurrency import EventKit
import NaturalLanguage
import SwiftUI
import Translation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct SelectionCommand: Identifiable, Codable, Equatable {
    /// A command's name as a Mac menu writes it, in title case: "Improve
    /// Writing", "Translate to Russian".
    static func menuTitle(_ name: String) -> String {
        let small: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to", "with"]
        return name.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { index, word in
            let lower = word.lowercased()
            if index > 0, small.contains(lower) { return lower }
            // A name that has its own capitals, iPhone, stays as it is.
            if word.dropFirst().contains(where: \.isUppercase) { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    var id: String
    var name: String
    var prompt: String
    var executor: String
    var enabled = true
    var custom = false
    var fieldsOnly = false
    var pagesOnly = false
    var site = ""
    var applyImmediately = false
    var shortcut = ""
    var result = "auto"
    var codeOnly = false
    /// Its own model when it runs on "claude" or "codex" (ModelChoice);
    /// nil for the agent's own, or the Commands default's.
    var model: String?
    var effort: String?

    enum OutputBehavior: String { case preview, replace }

    /// Keep saved commands compatible; the editor exposes one decision.
    var outputBehavior: OutputBehavior {
        get { applyImmediately && ["auto", "inPlace"].contains(result) ? .replace : .preview }
        set {
            applyImmediately = newValue == .replace
            result = "auto"
        }
    }

    static let builtIn: [SelectionCommand] = [
        .init(id: "improve", name: "Improve writing", prompt: "Rewrite more clearly. Keep the author's tone, language and formatting. Add no facts. Return only the rewritten text.", executor: "mac"),
        .init(id: "fix", name: "Fix spelling and grammar", prompt: "Fix only spelling and grammar mistakes. Change nothing else. Return only the corrected text.", executor: "mac"),
        .init(id: "shorter", name: "Make shorter", prompt: "Make this about half as long. Keep the meaning, tone and language. Return only the result.", executor: "mac", enabled: false),
        .init(id: "longer", name: "Make longer", prompt: "Expand using only detail already implied. Add no facts. Keep the tone and language. Return only the result.", executor: "mac", enabled: false),
        .init(id: "formal", name: "Make more formal", prompt: "Keep the content and language. Use a more formal register. Return only the result.", executor: "mac", enabled: false),
        .init(id: "friendly", name: "Make friendlier", prompt: "Keep the content and language. Make the tone warmer. Return only the result.", executor: "mac", enabled: false),
        .init(id: "translate", name: "Translate", prompt: "Translate faithfully to {language}. Preserve formatting. Return only the translation.", executor: "mac"),
        .init(id: "summarize", name: "Summarize", prompt: "Summarize in one to three sentences in {language}. Return only the summary.", executor: "mac"),
        .init(id: "explain", name: "Explain simply", prompt: "Explain this clearly to someone new to the topic in {language}. Return only the explanation.", executor: "agent"),
        .init(id: "define", name: "Define", prompt: "Define this in context, briefly, in {language}. Return only the definition.", executor: "mac", enabled: false),
        .init(id: "explain-code", name: "Explain code", prompt: "Explain what this code does and anything surprising. Return only the explanation.", executor: "agent", enabled: false, result: "foot"),
        .init(id: "find-bugs", name: "Find bugs", prompt: "List real bugs, most severe first. If none are found, say so plainly.", executor: "agent", enabled: false, result: "foot"),
        .init(id: "quote", name: "Copy as quote", prompt: "", executor: "local", enabled: false),
        .init(id: "calendar", name: "Add to calendar", prompt: "", executor: "local", enabled: false, result: "beside"),
        .init(id: "map", name: "Show on map", prompt: "", executor: "local", enabled: false, result: "beside"),
        .init(id: "call", name: "Call with iPhone", prompt: "", executor: "local", enabled: false, result: "beside"),
        .init(id: "convert", name: "Convert", prompt: "", executor: "local", enabled: false, result: "beside")
    ]
}

@MainActor
struct SelectionSnapshot {
    var text: String
    var around: String
    var rect: CGRect
    var editable: Bool
    var recordID: String?
    var preciseRect: Bool
    var truncated: Bool
    var code: Bool
    var site: String
    var url: String
    var title: String
    var language: String
    var targetLanguage: String
    var fontSize: Double
    var fontFamily: String
    /// The text's line height in points, as the page sets it.
    var lineHeight: Double
    /// The text's block, a field's or a paragraph's, inside its padding:
    /// a result drawn in place wraps where the page's lines do. Nil when
    /// the page didn't say.
    var box: CGRect?
    var foreground: Color
    var ground: Color
    var dark: Bool?
    var date: Date?
    var address: Bool
    var phone: String?
    var converts: Bool
    let words: Int

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue
                                                      | NSTextCheckingResult.CheckingType.address.rawValue
                                                      | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    /// Nothing selected: words asked in the field (Browser.askInField),
    /// about the page it came up over, when there is one.
    @MainActor init(asking tab: Tab?) {
        text = ""
        around = ""
        rect = .zero
        editable = false
        recordID = nil
        preciseRect = false
        truncated = false
        code = false
        site = tab?.address?.host() ?? ""
        url = tab?.address?.absoluteString ?? ""
        title = tab?.title ?? ""
        language = ""
        targetLanguage = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "en" } ?? "en"
        fontSize = 13
        fontFamily = "-apple-system"
        lineHeight = 16
        box = nil
        foreground = Color(nsColor: Palette.NS.ink)
        ground = Color(nsColor: Palette.NS.ground)
        dark = nil
        date = nil
        address = false
        phone = nil
        converts = false
        words = 0
    }

    init?(_ value: Any?, tab: Tab) {
        guard let data = value as? [String: Any],
              let text = data["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let place = data["rect"] as? [String: Double] else { return nil }
        self.text = text
        around = data["around"] as? String ?? ""
        rect = CGRect(x: place["x"] ?? 0, y: place["y"] ?? 0, width: place["width"] ?? 1, height: place["height"] ?? 20)
        editable = data["editable"] as? Bool ?? false
        recordID = data["recordID"] as? String
        preciseRect = data["preciseRect"] as? Bool ?? true
        truncated = data["truncated"] as? Bool ?? false
        code = data["code"] as? Bool ?? false
        site = tab.address?.host() ?? ""
        url = tab.address?.absoluteString ?? ""
        title = tab.title
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1_200)))
        language = recognizer.dominantLanguage?.rawValue ?? ""
        let aroundRecognizer = NLLanguageRecognizer()
        aroundRecognizer.processString(String(around.prefix(1_200)))
        let preferred = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "en" } ?? "en"
        targetLanguage = editable && aroundRecognizer.dominantLanguage != nil
            ? (aroundRecognizer.dominantLanguage?.rawValue ?? preferred) : preferred
        fontSize = data["fontSize"] as? Double ?? 13
        fontFamily = data["fontFamily"] as? String ?? "Arial"
        lineHeight = data["lineHeight"] as? Double ?? fontSize * 1.2
        self.box = (data["box"] as? [String: Double]).map { CGRect(x: $0["x"] ?? 0, y: $0["y"] ?? 0, width: $0["width"] ?? 0, height: $0["height"] ?? 0) }
        foreground = Color(nsColor: NSColor(hex: data["foreground"] as? String ?? "") ?? Palette.NS.ink)
        ground = Color(nsColor: NSColor(hex: data["ground"] as? String ?? "") ?? Palette.NS.ground)
        dark = data["dark"] as? Bool
        let detected = String(text.prefix(2_000))
        let matches = Self.detector?.matches(in: detected, range: NSRange(detected.startIndex..., in: detected)) ?? []
        date = matches.first(where: { $0.resultType == .date })?.date
        address = matches.contains { $0.resultType == .address }
        phone = matches.first(where: { $0.resultType == .phoneNumber })?.phoneNumber
        converts = text.count < 80 && Calc.answer(text) != nil
        // Words as the language has them: Chinese and Japanese have no
        // spaces, and counted by spaces a sentence was one word.
        let tokenizer = NLTokenizer(unit: .word)
        let sample = String(text.prefix(2_000))
        tokenizer.string = sample
        var count = 0
        tokenizer.enumerateTokens(in: sample.startIndex..<sample.endIndex) { _, _ in
            count += 1
            return count <= 80
        }
        words = count
    }

    var systemFont: Bool { ["-apple-system", "BlinkMacSystemFont", "system-ui"].contains(fontFamily) }

    var canShowInPlace: Bool {
        guard preciseRect, !truncated else { return false }
        return systemFont || NSFont(name: fontFamily, size: CGFloat(fontSize)) != nil
    }

    /// The page's gap between lines, over what the font has of its own:
    /// the preview's lines fall where the field's do.
    var extraLineSpacing: Double {
        let size = CGFloat(max(fontSize, 8))
        let font = systemFont ? NSFont.systemFont(ofSize: size) : NSFont(name: fontFamily, size: size) ?? .systemFont(ofSize: size)
        return max(0, lineHeight - Double(font.ascender - font.descender + font.leading))
    }
}

@MainActor
final class SelectionCommands: ObservableObject {
    enum Stage: Equatable { case closed, running, preview, failed }
    @Published var stage: Stage = .closed
    @Published var snapshot: SelectionSnapshot?
    @Published var hint: SelectionSnapshot?
    @Published var output = ""
    @Published var showOriginal = false
    @Published var error = ""
    @Published var noChange = false
    @Published var command: SelectionCommand?
    @Published var commands: [SelectionCommand] = SelectionCommand.builtIn
    /// The answer is in the ⌘J field (FieldAnswer), Raycast's output view,
    /// not over or beside the text: a command picked from the field's list
    /// answers there, and what is said next follows it up there.
    @Published var answering = false
    /// The answers before the one showing, each with what asked for it
    /// (nil: the command itself), oldest first.
    @Published var turns: [Turn] = []
    /// The follow-up the answer showing is for; nil for the command's own.
    @Published var asked: String?
    /// Being put into the page from the field: the field has gone, the
    /// preview over the text stays away while the page takes it.
    @Published var handing = false
    /// Replace went in: the page has the words, and the result drawn over
    /// them stays a moment while its wash fades (SelectionInk).
    @Published var replacing = false
    /// A command uses the page's shared agent dock, never a second card
    /// beside the selection. No dock exists before a command starts.
    @Published private(set) var docked = false
    @Published private(set) var applying = false
    private var insertionPending = false
    enum Receipt: String { case replaced = "Replaced", cancelled = "Cancelled", restored = "Original restored", copied = "Copied" }
    @Published private(set) var receipt: Receipt?
    private var receiptTask: Task<Void, Never>?
    var showsDock: Bool { docked && !answering && stage != .closed }
    var showsDockResult: Bool { showsDock && stage == .preview && !applying && receipt == nil }
    /// Under an Ask's answer, the pages it came from (AskFromDay), over
    /// them what stretch of time, and the one ↓ moved to.
    @Published var sources: [AnswerSource] = []
    @Published var sourceCaption = ""
    @Published var sourceSpot: Int?
    /// While an Ask with time words is answered, the stretch it looks
    /// through: "this morning", for the live line.
    @Published var lookingThrough: String?
    /// What the question was handed from your day, numbered.
    private var offered: AskFromDay.Context?
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let asked: String?
        let answer: String
    }
    private var habits: [String: [String]] = [:]
    private var pageActions: [Skills.Action] = []
    private weak var tab: Tab?
    private weak var hintTab_: Tab?
    var activeTab: Tab? { tab }
    var hintTab: Tab? { hintTab_ }
    private var task: Task<Void, Never>?
    private var generation = 0
    /// The agent's session answering now, and the last one: published, so
    /// the answer's Open in Chat is there from its first moment.
    @Published private var sessionID: String?
    @Published private var lastSessionID: String?

    private var macModelChanges: AnyCancellable?

    init() {
        load()
        loadHabits()
        macModelChanges = NotificationCenter.default.publisher(for: AppleModelAccess.changed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    if !AppleModelAccess.usable() { self?.hideHint() }
                }
            }
    }

    /// Hiding the automatic suggestion must not cancel an explicit command.
    func hideHint() {
        if hint != nil { hint = nil }
        hintTab_ = nil
    }
    static func menuSuggestions(_ commands: [SelectionCommand]) -> [SelectionCommand] {
        let ids = ["improve", "fix", "translate"]
        return ids.compactMap { id in commands.first { $0.id == id && $0.enabled } }
    }
    private static var file: URL { Store.file("commands.json") }
    private static var habitsFile: URL { Store.file("selection-habits.json") }

    func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode([SelectionCommand].self, from: data) else { return }
        commands = Self.merged(saved)
    }

    static func merged(_ saved: [SelectionCommand]) -> [SelectionCommand] {
        let builtIns = Set(SelectionCommand.builtIn.map(\.id))
        var seen = Set<String>()
        let ordered = saved.filter { command in
            guard (command.custom || builtIns.contains(command.id)), !seen.contains(command.id) else { return false }
            seen.insert(command.id)
            return true
        }
        return ordered + SelectionCommand.builtIn.filter { !seen.contains($0.id) }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    private func loadHabits() {
        guard let data = try? Data(contentsOf: Self.habitsFile),
              let saved = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        habits = saved
    }

    private func record(_ command: SelectionCommand, site: String) {
        guard tab?.shy != true, !site.isEmpty, command.id != "ask" else { return }
        habits[site, default: []].append(command.id)
        habits[site] = Array(habits[site, default: []].suffix(20))
        if let data = try? JSONEncoder().encode(habits) { try? data.write(to: Self.habitsFile, options: .atomic) }
    }

    /// Scrolling moves the text out from under the list and the preview:
    /// they go with the first scroll rather than float over other words.
    private var scrolling: Any?

    private func watchScroll() {
        guard scrolling == nil else { return }
        scrolling = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                // In the field the answer scrolls in its own list, and the
                // selection it is for is kept by its range, not where it sits.
                guard let self, self.stage != .closed, !self.answering, !self.docked,
                      abs(event.scrollingDeltaY) + abs(event.scrollingDeltaX) > 0.5 else { return }
                self.close()
            }
            return event
        }
    }

    /// The answer's chat, for the column: the session let go of here, so
    /// closing the field leaves it at work. Nil for this Mac's model.
    func handOff() -> String? {
        guard let id = sessionID ?? lastSessionID else { return nil }
        sessionID = nil
        lastSessionID = nil
        task?.cancel()
        task = nil
        receiptTask?.cancel()
        receiptTask = nil
        return id
    }

    /// Whether the answer has a chat to hand to the column.
    var hasChat: Bool { sessionID != nil || lastSessionID != nil }

    /// Answered by an agent, whose chat it will be: the Mac's own model and
    /// the commands that need neither have none.
    var hasAgent: Bool {
        hasChat || (stage == .running && AgentPlan.isPlan(command?.executor))
    }

    func close() {
        if let scrolling { NSEvent.removeMonitor(scrolling) }
        scrolling = nil
        generation += 1
        task?.cancel()
        task = nil
        receiptTask?.cancel()
        receiptTask = nil
        if let sessionID { _ = Agents.shared.stop(sessionID) }
        // Called on every touch of a page, each event of a scroll among
        // them. A write to a published property, the same value or not,
        // tells every view watching this one to draw again, and with
        // nothing open that laid the whole window out on every frame
        // of a page's scroll.
        if sessionID != nil { sessionID = nil }
        if lastSessionID != nil { lastSessionID = nil }
        if stage != .closed { stage = .closed }
        if snapshot != nil { snapshot = nil }
        if hint != nil { hint = nil }
        hintTab_ = nil
        if !output.isEmpty { output = "" }
        if showOriginal { showOriginal = false }
        if !error.isEmpty { error = "" }
        if noChange { noChange = false }
        tab = nil
        pageActions = []
        if answering { answering = false }
        if handing { handing = false }
        if replacing { replacing = false }
        if docked { docked = false }
        if applying { applying = false }
        insertionPending = false
        if receipt != nil { receipt = nil }
        if !turns.isEmpty { turns = [] }
        if asked != nil { asked = nil }
        clearSources()
        offered = nil
    }

    private func clearSources() {
        if lookingThrough != nil { lookingThrough = nil }
        if !sources.isEmpty { sources = [] }
        if !sourceCaption.isEmpty { sourceCaption = "" }
        if sourceSpot != nil { sourceSpot = nil }
    }

    /// The answer's last line read for the pages it names, and their rows
    /// shown; picking up, the thread's row chosen first.
    private func cite(_ text: String) -> String {
        guard let offered else { return text }
        let (answer, numbers) = AskFromDay.cited(text)
        sources = AskFromDay.rows(offered, numbers: numbers)
        sourceCaption = offered.caption
        sourceSpot = offered.folder != nil && !sources.isEmpty ? 0 : nil
        return answer
    }

    /// The rows an answer would have, for the bench's pictures: the
    /// context handed, the numbers named.
    func cite(_ context: AskFromDay.Context, numbers: [Int]?) {
        offered = context
        sources = AskFromDay.rows(context, numbers: numbers)
        sourceCaption = context.caption
        sourceSpot = context.folder != nil && !sources.isEmpty ? 0 : nil
    }

    /// While the words come, the numbers line kept out of sight.
    private func shown(_ partial: String) -> String {
        offered == nil ? partial : AskFromDay.streaming(partial)
    }

    /// The commands whose result goes back into the text, a rewrite of it:
    /// drawn in the text's place (SelectionInk) rather than on a card.
    static let rewriteIDs: Set<String> = ["improve", "fix", "shorter", "longer", "formal", "friendly", "translate"]

    static func rewrites(_ command: SelectionCommand?, editable: Bool) -> Bool {
        guard let command, command.result != "draft" else { return false }
        if rewriteIDs.contains(command.id) { return true }
        return command.custom && (command.result == "inPlace" || (command.result == "auto" && editable))
    }

    /// Put in a state as a command would leave it, without running one:
    /// the bench's pictures of every state.
    func show(_ command: SelectionCommand, on tab: Tab, snapshot: SelectionSnapshot, stage: Stage,
              output: String, error: String = "") {
        var command = command
        if command.executor != "local" {
            let behavior = command.outputBehavior
            command.outputBehavior = behavior
        }
        if self.tab !== tab || self.snapshot?.text != snapshot.text {
            close()
            self.tab = tab
            self.snapshot = snapshot
        }
        self.command = command
        self.output = output
        self.error = error
        self.stage = stage
        docked = command.executor != "local"
    }

    /// The page took the words: the wash fades off them, then the drawing
    /// goes and the page's own words are left where they were.
    private func landed() {
        if docked {
            finish(.replaced)
            applying = false
            return
        }
        replacing = true
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current, self.replacing else { return }
                self.close()
            }
        }
    }

    private func finish(_ receipt: Receipt) {
        self.receipt = receipt
        receiptTask?.cancel()
        let current = generation
        receiptTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(receipt == .replaced ? 4 : 1.4))
            guard !Task.isCancelled, let self, self.generation == current else { return }
            self.close()
        }
    }

    func cancelCommand() {
        guard docked, stage == .running, !applying else { return }
        generation += 1
        task?.cancel()
        task = nil
        if let sessionID { _ = Agents.shared.stop(sessionID) }
        sessionID = nil
        output = ""
        stage = .preview
        finish(.cancelled)
    }

    /// Undo is scoped to this replacement. The page refuses it if another
    /// edit has happened since, rather than undoing something the user typed.
    func undoReplacement() {
        guard receipt == .replaced, !applying, let web = tab?.builtPage else { return }
        applying = true
        let current = generation
        let id = Self.javaScriptValue(snapshot?.recordID ?? "")
        web.run("window.__yabUndoSelection?.(\(id)) ?? 'gone'", in: .client, frame: readFrame) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.applying = false
                if (try? result.get()) as? String == "ok" { self.finish(.restored) }
                else {
                    self.receiptTask?.cancel()
                    self.receipt = nil
                    self.output = ""
                    self.error = "The text changed after replacement. Use Undo in the field instead."
                    self.stage = .failed
                }
            }
        }
    }

    func copyResult() {
        if docked {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
            finish(.copied)
        } else {
            copy()
            close()
        }
    }

    /// Back to the selection's commands: the field, in its place, over
    /// the same selection.
    func back() {
        let snap = snapshot
        let tab = tab
        close()
        if let snap, let tab { BrowserWindows.shared.owner(of: tab.id)?.browser.editSelection(snap) }
    }

    func open(on tab: Tab, command id: String? = nil) {
        // AI off, or nothing to ask (AIUse.offers): no commands on a selection.
        guard let web = tab.builtPage, AIUse.offers else { return }
        // Again over a result: back to the selection's commands.
        if stage != .closed, self.tab === tab, id == nil {
            back()
            return
        }
        close()
        load()
        loadHabits()
        let current = generation
        read(web) { [weak self, weak tab] value in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                guard let tab, let snapshot = SelectionSnapshot(value, tab: tab) else {
                    // Nothing selected: the task line, the site's actions
                    // under it.
                    if id == nil, let tab { TaskLine.shared.open(on: tab) }
                    return
                }
                // A command named, by its key or the page's menu: it runs.
                // Otherwise the field, in the selection's place, lists them.
                guard let id else {
                    BrowserWindows.shared.owner(of: tab.id)?.browser.editSelection(snapshot)
                    return
                }
                self.run(id, on: tab, snapshot: snapshot)
            }
        }
    }

    /// A command run on a selection already read, the field's: read again
    /// as the field goes, the page has not had the cursor back yet and says
    /// nothing is selected.
    func run(_ id: String, on tab: Tab, snapshot: SelectionSnapshot, inField: Bool = false) {
        load()
        guard let command = commands.first(where: { $0.id == id && $0.enabled }) else { return }
        run(command, on: tab, snapshot: snapshot, inField: inField)
    }

    /// `inField`: from the ⌘J field's list, answered in the field.
    func run(_ command: SelectionCommand, on tab: Tab, snapshot: SelectionSnapshot, inField: Bool = false) {
        close()
        if TaskLine.shared.tab == tab.id { TaskLine.shared.close() }
        loadHabits()
        self.tab = tab
        self.snapshot = snapshot
        answering = inField
        pageActions = Hints.shared.actions(on: tab)
        watchScroll()
        run(command)
    }

    /// Words said under an answer in the field: the same agent carries
    /// on from its own conversation (text only, as the command ran), and
    /// the answer before goes up into what was said.
    func follow(_ words: String) {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard answering, !words.isEmpty, let snap = snapshot, var command, stage != .running else { return }
        if !output.isEmpty { turns.append(Turn(asked: asked, answer: output)) }
        asked = words
        // Answered on this Mac, or with nothing to carry on from: your
        // agent, told what was selected and what was said about it.
        let carried = AgentPlan.isPlan(command.executor) ? lastSessionID : nil
        if carried == nil {
            let pick = agent(for: command)
            command.executor = pick.cli
            command.model = pick.model
            command.effort = pick.effort
        }
        let before = turns.map { ($0.asked.map { "They asked: \($0)\n" } ?? "") + "You answered:\n\($0.answer)" }.joined(separator: "\n\n")
        let prompt = carried != nil ? words : snap.text.isEmpty ? """
            They asked in their browser's field: \(command.prompt)

            \(before)

            They now say: \(words)
            """ : """
            The user selected this text on a page:
            \(String(snap.text.prefix(20_000)))

            \(before)

            They now say: \(words)
            """
        self.command = command
        stage = .running
        output = ""
        error = ""
        noChange = false
        clearSources()
        generation += 1
        let current = generation
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await ask(prompt, command: command, resume: carried, saying: words) { [weak self] partial in
                    guard let self, self.generation == current, self.stage == .running else { return }
                    self.output = Self.clean(self.shown(partial))
                }
                guard !Task.isCancelled, generation == current else { return }
                let clean = cite(Self.clean(result))
                if clean.isEmpty { error = "No response. Try again."; stage = .failed; return }
                output = clean
                stage = .preview
            } catch {
                guard !Task.isCancelled, generation == current else { return }
                self.error = error.localizedDescription
                stage = .failed
            }
        }
    }

    /// The command again on another model, from the field's model menu.
    func again(with choice: ModelChoice) {
        guard var command, let cli = choice.cli, AgentPlan.isPlan(cli) || cli == "mac" else { return }
        command.executor = cli
        command.model = cli == "mac" ? nil : choice.model
        command.effort = cli == "mac" ? nil : choice.effort
        turns = []
        asked = nil
        lastSessionID = nil
        run(command)
    }

    /// Stops the answer being written, keeping what came so far.
    func stop() {
        guard stage == .running else { return }
        generation += 1
        task?.cancel()
        task = nil
        if let sessionID { _ = Agents.shared.stop(sessionID) }
        sessionID = nil
        if output.isEmpty {
            error = "Stopped"
            stage = .failed
        } else {
            stage = .preview
        }
    }

    /// The answer showing, put into the page (or wherever its command puts
    /// it) from the field: the field is already gone, so a page that
    /// refuses it says so at the text, as a command run from the page would.
    func handOver() {
        guard answering else { return apply() }
        // A question's answer: copied, with no page to put it into.
        if snapshot?.text.isEmpty == true {
            copy()
            if let tab, let browser = BrowserWindows.shared.owner(of: tab.id)?.browser { browser.close() }
            close()
            return
        }
        answering = false
        handing = true
        if let tab, let browser = BrowserWindows.shared.owner(of: tab.id)?.browser { browser.close() }
        // Once the page has the keyboard back: typed into a page that hasn't,
        // the words go nowhere though the page says they went in.
        waitForPage(generation, tries: 12)
    }

    private func waitForPage(_ current: Int, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.generation == current, self.stage == .preview else { return }
            let web = self.tab?.builtPage
            let responder = web?.window?.firstResponder as? NSView
            if let web, let responder, !responder.isDescendant(of: web), tries > 0 {
                self.waitForPage(current, tries: tries - 1)
            } else {
                self.apply()
            }
        }
    }

    func maybeHint(on tab: Tab) {
        guard AppleModelAccess.usable(), stage == .closed, hint == nil,
              !Store.settings.bool(forKey: "selection.hint.shown"),
              let web = tab.builtPage else { return }
        let current = generation
        read(web) { [weak self, weak tab] value in
            MainActor.assumeIsolated {
                guard AppleModelAccess.usable(), let self, self.generation == current, let tab,
                      let snap = SelectionSnapshot(value, tab: tab),
                      snap.editable, snap.words > 5 else { return }
                self.hintTab_ = tab
                self.hint = snap
                Store.settings.set(true, forKey: "selection.hint.shown")
            }
        }
    }

    /// What the selection now is offered, best first.
    var available: [SelectionCommand] {
        guard let snap = snapshot else { return [] }
        return offered(for: snap, actions: pageActions)
    }

    /// The commands a selection is offered, best first, with a site's own
    /// actions ahead: the list's, and the field's rows over the page.
    func offered(for snap: SelectionSnapshot, actions: [Skills.Action]) -> [SelectionCommand] {
        let items = commands.filter { $0.enabled && (!$0.fieldsOnly || snap.editable) && (!$0.pagesOnly || !snap.editable)
            && (!$0.codeOnly || snap.code) && Self.matchesSite($0.site, snap: snap) }
            .filter { command in
                switch command.id {
                case "calendar": return snap.date != nil
                case "map": return snap.address
                case "call": return snap.phone != nil
                case "convert": return snap.converts
                default: return true
                }
            }
            // Only what can run here now: no row that only says to connect an agent.
            .filter { runner($0, for: snap) != nil }
            .map { command in
                var shown = command
                if shown.id == "translate" {
                    let name = Locale(identifier: "en_US").localizedString(forLanguageCode: snap.targetLanguage) ?? snap.targetLanguage
                    shown.name = "Translate to \(name)"
                }
                return shown
            }
        let preferred: [String]
        if snap.code { preferred = ["explain-code", "find-bugs"] }
        else if snap.editable && !snap.language.isEmpty && snap.language != snap.targetLanguage { preferred = ["translate", "improve", "fix"] }
        else if snap.editable { preferred = ["improve", "fix", "shorter", "formal", "translate"] }
        else if snap.words <= 3 { preferred = ["define", "translate", "explain"] }
        else if snap.words > 80 { preferred = ["summarize", "explain", "translate"] }
        else { preferred = ["explain", "translate", "summarize"] }
        var ranked = preferred.compactMap { id in items.first { $0.id == id } }
        let recent = Array(habits[snap.site, default: []].suffix(5))
        if let often = ranked.first(where: { id in recent.filter { $0 == id.id }.count >= 3 }),
           let index = ranked.firstIndex(of: often), index > 0 {
            ranked.remove(at: index)
            ranked.insert(often, at: 0)
        }
        let skills = !Agents.ready ? [] : actions.enumerated().map { index, action in
            SelectionCommand(id: "skill-\(index)", name: action.title,
                             prompt: action.prompt, executor: "agent", result: action.draft == nil ? "foot" : "draft")
        }
        let local = ["calendar", "map", "call", "convert"].compactMap { id in items.first { $0.id == id } }
        // A date, a place or a number first only when that is what was
        // selected: in a whole reply it is a word among others, and the
        // reply is what is being worked on.
        return snap.words <= 8
            ? skills + local + ranked + items.filter { !preferred.contains($0.id) && !local.contains($0) }
            : skills + ranked + local + items.filter { !preferred.contains($0.id) && !local.contains($0) }
    }

    /// Commands the typed words name: a word that starts with them first,
    /// then the letters anywhere in a name.
    static func matching(_ words: String, in commands: [SelectionCommand]) -> [SelectionCommand] {
        let q = words.lowercased()
        let starts = commands.filter { command in
            command.name.lowercased().hasPrefix(q) || command.name.split(separator: " ").contains { $0.lowercased().hasPrefix(q) }
        }
        return starts + commands.filter { !starts.contains($0) && $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// The selection on a page, read without opening anything: for the
    /// field's rows over the page. Nil when nothing is selected.
    func peek(on tab: Tab, done: @escaping (SelectionSnapshot?) -> Void) {
        guard let web = tab.builtPage else { done(nil); return }
        read(web) { [weak tab] value in
            MainActor.assumeIsolated {
                guard let tab else { done(nil); return }
                done(SelectionSnapshot(value, tab: tab))
            }
        }
    }

    private static func matchesSite(_ pattern: String, snap: SelectionSnapshot) -> Bool {
        guard !pattern.isEmpty else { return true }
        if pattern == snap.site { return true }
        let normalized = pattern.contains("://") ? snap.url : snap.site + (URLComponents(string: snap.url)?.path ?? "")
        let regex = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
        return normalized.range(of: regex, options: .regularExpression) != nil
    }

    func take(_ event: NSEvent, on tab: Tab?) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if let tab, AIUse.offers,
           Keymap.shared.systemBrowserAction(for: event) == nil,
           let command = commands.first(where: { $0.enabled && !$0.shortcut.isEmpty && Hotkey(stored: $0.shortcut)?.heard(in: event) == true }) {
            open(on: tab, command: command.id)
            return true
        }
        // ⌘J is there only while AI is (AIUse.offers); otherwise the page has it.
        if Keymap.shared.matches(event, .agentAsk), let tab, AIUse.offers {
            // A second ask while the inline task line is up expands that
            // draft directly. The page may still report an old selection
            // while its own field has focus, so don't read it again here.
            if stage == .closed, TaskLine.shared.tab == tab.id {
                TaskLine.shared.toChat(on: tab)
                return true
            }
            // An answer at the page's foot that takes a follow-up: ⌘J is
            // its Ask (AnswerKeys), not a new task.
            if stage == .closed, AnswerKeys.shared.offers[tab.id]?.contains(.ask) == true { return false }
            open(on: tab)
            return true
        }
        if TaskLine.shared.take(event, on: tab) { return true }
        guard stage != .closed else { return false }
        if receipt == .replaced, flags == .command, event.keyCode == 6 {
            undoReplacement()
            return true
        }
        if applying { return event.keyCode == 53 && flags.isEmpty }
        if event.keyCode == 53, flags.isEmpty {
            if showsDock, stage == .running { cancelCommand() } else { close() }
            return true
        }
        // A completion is a receipt, never another request to apply.
        if receipt != nil || applying { return false }
        if stage == .preview || stage == .failed {
            if flags.isEmpty && [36, 76].contains(event.keyCode) {
                if stage == .failed && output.isEmpty {
                    if noChange { close() }
                    else if command?.executor == "mac" { retryWithAgent() }
                    else { back() }
                } else { apply() }
                return true
            }
            if Keymap.shared.matches(event, .selectionCopy) { copy(); return true }
            if Keymap.shared.matches(event, .selectionRetry), let command { run(command); return true }
        }
        return false
    }

    func run(_ command: SelectionCommand, immediate: Bool = false) {
        guard let snap = snapshot else { return }
        if command.id == "ask-task", let tab {
            close()
            TaskLine.shared.open(on: tab, selection: snap.text)
            return
        }
        var command = command
        if !command.id.hasPrefix("skill-") {
            guard let runner = runner(command) else {
                // Nothing to run it on: where to get something, rather than a failure.
                if let tab, let owner = BrowserWindows.shared.owner(of: tab.id) { SettingsWindow.shared.showAgents(for: owner.browser) }
                close()
                return
            }
            if runner != "local" && runner != "mac" {
                let pick = agent(for: command)
                command.executor = pick.cli
                command.model = pick.model
                command.effort = pick.effort
            } else if runner != "local" { command.executor = runner }
        }
        if command.id.hasPrefix("skill-"), let index = Int(command.id.dropFirst(6)),
           let tab, pageActions.indices.contains(index) {
            Agents.shared.act(pageActions[index], on: tab)
            close()
            return
        }
        if command.executor != "local" {
            let behavior = command.outputBehavior
            command.outputBehavior = behavior
        }
        record(command, site: snap.site)
        self.command = command
        docked = !answering && (command.executor != "local" || command.applyImmediately || immediate)
        applying = false
        receipt = nil
        receiptTask?.cancel()
        stage = .running
        output = ""
        error = ""
        noChange = false
        clearSources()
        offered = nil
        generation += 1
        let current = generation
        task?.cancel()
        if (immediate || command.applyImmediately), ["auto", "inPlace"].contains(command.result), !snap.editable {
            error = "Select text in an editable field to replace it."
            stage = .failed
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // The words as they come, into the preview: the first ones
                // in well under a second, rather than all of them at the end.
                let result = try await generate(command, snapshot: snap) { [weak self] partial in
                    guard let self, self.generation == current, self.stage == .running,
                          !immediate, !command.applyImmediately else { return }
                    self.output = Self.clean(self.shown(partial))
                }
                guard !Task.isCancelled, generation == current else { return }
                receive(result, immediate: immediate)
            } catch {
                guard !Task.isCancelled, generation == current else { return }
                self.error = error.localizedDescription
                stage = .failed
            }
        }
    }

    /// Final generation is applied in the same turn. The direct mode never
    /// enters a visible preview, even for a short or already-streamed result.
    func receive(_ result: String, immediate: Bool = false) {
        guard stage == .running, let snap = snapshot, let command else { return }
        let clean = cite(Self.clean(result))
        if (immediate || command.applyImmediately), ["auto", "inPlace"].contains(command.result), !snap.editable {
            output = clean
            error = "Select text in an editable field to replace it."
            stage = .failed
            return
        }
        if clean.isEmpty { output = ""; error = "No response. Try again or ask an agent."; stage = .failed; return }
        if clean == snap.text { output = ""; error = "Nothing to change"; noChange = true; stage = .failed; return }
        output = clean
        if !docked, !answering, command.result == "foot" || (command.result == "auto" && !snap.editable && clean.count > 500) {
            tab?.answer = (session: lastSessionID ?? "", text: clean)
            close()
            return
        }
        let direct = immediate || command.applyImmediately
        if direct && docked { applying = true }
        stage = .preview
        if direct { answering ? handOver() : apply() }
    }

    /// Who a command would run on now: the Mac's model when it has one and
    /// the selection fits it, else your agent; "local" for what needs
    /// neither, nil when nothing here can run it. The row says this before
    /// it is chosen, not a failure after.
    func runner(_ command: SelectionCommand, for snap: SelectionSnapshot? = nil) -> String? {
        if command.executor == "local" || ["quote", "calendar", "map", "call", "convert"].contains(command.id) { return "local" }
        if command.executor == "mac", FormModel.ready, ((snap ?? snapshot)?.text.count ?? 0) <= Self.macLimit { return "mac" }
        let cli = agent(for: command).cli
        // Gemini answers without the connection tasks need.
        return AgentModels.here(cli) && (cli == "gemini" || Agents.ready) ? cli : nil
    }

    /// Who runs it in words for its row: the model when one is chosen,
    /// "Claude" or "ChatGPT" when the agent picks its own.
    func agentTitle(_ command: SelectionCommand) -> String {
        let pick = agent(for: command)
        return AgentModels.find(pick.cli, pick.model)?.name ?? AgentSetupModel.name(pick.cli)
    }

    /// The agent, model and effort a command goes to when this Mac doesn't
    /// take it: its own, else the Commands default (Settings › AI › Models).
    func agent(for command: SelectionCommand) -> (cli: String, model: String?, effort: String?) {
        if AgentPlan.isPlan(command.executor) {
            return (command.executor, command.model, command.effort)
        }
        return ModelDefaults.shared.pickNow(.commands)
    }

    /// Whose plan Ask on the failed Mac command goes to: the Commands
    /// default's, as retryWithAgent runs it.
    var retryName: String { AgentSetupModel.name(ModelDefaults.shared.pickNow(.commands).cli) }

    func retryWithAgent() {
        guard var command else { return }
        command.executor = "agent"
        command.model = nil
        command.effort = nil
        run(command)
    }

    private func generate(_ command: SelectionCommand, snapshot snap: SelectionSnapshot,
                          partial: @escaping (String) -> Void = { _ in }) async throws -> String {
        if command.id == "quote" { return "“\(snap.text)”\n\(snap.url)" }
        if command.id == "calendar", let date = snap.date {
            return "Add “\(snap.text)” on \(date.englishFormatted(date: .abbreviated, time: .shortened))"
        }
        if command.id == "map" { return "Open “\(snap.text)” in Maps" }
        if command.id == "call" { return "Call \(snap.phone ?? snap.text)" }
        if command.id == "convert", let answer = Calc.answer(snap.text) { return answer.result }
        if #available(macOS 26, *), command.id == "translate", !snap.language.isEmpty {
            let source = Locale.Language(identifier: snap.language)
            let target = Locale.Language(identifier: snap.targetLanguage)
            if await LanguageAvailability().status(from: source, to: target) == .installed {
                return try await TranslationSession(installedSource: source, target: target).translate(snap.text).targetText
            }
        }
        // Words asked in the field, nothing selected: a question, not a
        // text to transform.
        let asking = snap.text.isEmpty && command.id == "ask"
        let full = asking ? await question(command.prompt, snapshot: snap) : await transform(command, snapshot: snap)
        if command.executor == "local" { return snap.text }
        if command.executor == "mac" {
            guard FormModel.ready else { throw SelectionError.message("The Mac model isn't available. Ask an agent instead?") }
            // The Mac's model reads about 4,000 characters in all: a longer
            // selection would come back as a rewrite of its start, and
            // Replace would put that over the whole of it.
            guard snap.text.count <= Self.macLimit else {
                throw SelectionError.message("Too long for this Mac\u{2019}s model. Ask an agent instead?")
            }
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                try BoostContributions.charge(command.id)
                // The small model drifts into English on its own: Russian
                // improved came back English. The language is said outright.
                let tongue = snap.language.isEmpty ? "" : Locale(identifier: "en").localizedString(forLanguageCode: snap.language) ?? ""
                let keep = tongue.isEmpty ? "" : " Write in the language the request names; if it names none, in \(tongue), the language of the selected text."
                let session = LanguageModelSession(instructions: asking ? "Answer briefly and plainly, in the language of the question.\n\n" + Guide.productOverview
                                                   : "Return only the requested text. Do not add an introduction, quotes or new facts." + keep)
                var written = ""
                for try await snapshot in session.streamResponse(to: String(full.prefix(4_000))) {
                    written = snapshot.content
                    partial(written)
                }
                return written
            }
            #endif
            throw SelectionError.message("The Mac model isn't available. Ask an agent instead?")
        }
        return try await ask(asking ? full : "Only transform or answer the supplied text. Return only the result.\n\n\(full)",
                             command: command, resume: nil,
                             saying: command.custom ? command.prompt : SelectionCommand.menuTitle(command.name),
                             transforming: !asking, partial: partial)
    }

    /// A question asked in the field, for the agent: the words, the page
    /// the field came up over, and what the history has of the words,
    /// which is how "that article I read last week" gets its answer. The
    /// agent is text only (`ask`), so the page's words can ask it nothing.
    private func question(_ words: String, snapshot snap: SelectionSnapshot) async -> String {
        var parts = ["Answer this question the user typed into their browser's address field. The answer first, in a sentence or a few short lines, Markdown if it helps, no preamble, in the language of the question."]
        if !snap.url.isEmpty, let tab {
            // Read when the field came up over it, most likely (PageWords).
            let text = await PageWords.read(tab)
            parts.append("The page they have open, which the question may be about, or not at all:\n\(snap.title)\n\(snap.url)\n\n\(text)")
        }
        // Their day first: threads in the stretch the words name, numbered
        // for the rows under the answer (AskFromDay). With none, what the
        // words find in the history.
        if let span = DayThreads.span(words) { lookingThrough = span.words }
        if let day = await AskFromDay.context(for: words) {
            offered = day
            parts.append(day.text)
        } else {
            let found = await Diary.shared.found(words)
            if !found.isEmpty {
                parts.append("Pages from their history that the words find; use them only if the question is about something they read:\n\(found)")
            }
        }
        // Spending, subscriptions, an order: what the receipts in their mail
        // say, only while they let agents read their mail (Purchases).
        if Purchases.asks(words), MailCenter.agentsAllowed, MailCenter.shared.connected {
            let book = Purchases.shared
            if book.version == 0 { book.refresh(force: true) }
            for _ in 0..<40 where book.version == 0 { try? await Task.sleep(nanoseconds: 250_000_000) }
            let kept = [book.describe(kind: "subscriptions", query: ""), book.describe(kind: "orders", query: "")].joined(separator: "\n\n")
            parts.append("What they pay for and have coming, read from the receipts and shipping mail on this Mac; use it only if the question is about their spending, subscriptions, orders or deliveries:\n\(kept)")
        }
        parts.append("Question: \(words)")
        return parts.joined(separator: "\n\n")
    }

    /// A command's prompt over the selection, its variables filled in.
    private func transform(_ command: SelectionCommand, snapshot snap: SelectionSnapshot) async -> String {
        let hasSelectionVariable = command.prompt.contains("{selection}")
        var page = ""
        if command.prompt.contains("{page}"), let web = tab?.builtPage {
            if let sheet = await PageWords.sheet(web) { page = sheet } else {
                page = ((try? await web.run("document.body?.innerText?.slice(0, 12000) || ''", in: .client)) as? String) ?? ""
            }
        }
        let memory = command.prompt.contains("{memory}")
            ? String(((Memory.read("USER") ?? "") + "\n" + (Memory.read("memory") ?? "")).prefix(6_000))
            : ""
        let prompt = command.prompt
            .replacingOccurrences(of: "{selection}", with: snap.text)
            .replacingOccurrences(of: "{around}", with: snap.around)
            .replacingOccurrences(of: "{url}", with: snap.url)
            .replacingOccurrences(of: "{title}", with: snap.title)
            .replacingOccurrences(of: "{page}", with: page)
            .replacingOccurrences(of: "{memory}", with: memory)
            .replacingOccurrences(of: "{language}", with: Locale(identifier: snap.targetLanguage).localizedString(forLanguageCode: snap.targetLanguage) ?? snap.targetLanguage)
        return prompt + (hasSelectionVariable ? "" : "\n\nSelected text:\n\(String(snap.text.prefix(20_000)))")
            + "\n\nNearby text:\n\(String(snap.around.prefix(1_200)))"
    }

    /// Your agent, text only, on these words: the selection is the page's
    /// words, and a page can write words that ask for things; with no tools
    /// there is nothing for them to ask it to do. Its words come to
    /// `partial` as they are written (Claude Code's by the token, Codex's
    /// a whole message at a time), looked at ten times a second: the
    /// session is read, not watched, so nothing redraws for every word.
    private func ask(_ prompt: String, command: SelectionCommand, resume: String?, saying: String,
                     transforming: Bool = false,
                     partial: @escaping (String) -> Void) async throws -> String {
        try BoostContributions.charge(command.id)
        let pick = agent(for: command)
        // Its chat shows your words, not the prompt around them.
        Agents.shared.session(resume)?.saying.append(saying)
        let session = Agents.shared.run(prompt: prompt, cli: pick.cli, model: pick.model, effort: pick.effort,
                                        access: "text", quiet: true, name: "Selection command", resume: resume)
        session.selectionTransform = transforming
        session.boostOrigin = BoostContributions.pluginID(command.id)
        if resume == nil { session.saying.append(saying) }
        session.origin = .field
        if session.title == nil { session.title = command.custom ? Chat.title(from: command.prompt) : SelectionCommand.menuTitle(command.name) }
        sessionID = session.id
        let began = ContinuousClock.now
        var said = ""
        while session.state.live && !Task.isCancelled {
            if began.duration(to: .now) > .seconds(Self.patience) {
                _ = Agents.shared.stop(session.id)
                sessionID = nil
                throw SelectionError.message("The agent is taking too long. Try again or copy the selection.")
            }
            // Started on the other plan, this one out of room (Agents.choose):
            // the header names who answers, and follow-ups go there too.
            if var shown = self.command, shown.executor != session.cli, AgentPlan.isPlan(shown.executor) {
                shown.executor = session.cli
                shown.model = session.model
                self.command = shown
            }
            if session.result != said, !session.result.isEmpty {
                said = session.result
                partial(said)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        lastSessionID = session.id
        sessionID = nil
        if Task.isCancelled { throw CancellationError() }
        if session.state != .done { throw SelectionError.message(session.result.isEmpty ? "The agent could not answer" : session.result) }
        return session.result
    }

    /// How long an answer may take before it is given up on, in seconds.
    static var patience = 60

    static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Here is the improved version:", "Here is the revised text:", "Here is the translation:"] {
            if value.lowercased().hasPrefix(prefix.lowercased()) {
                value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return value
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        if let tab, let browser = BrowserWindows.shared.owner(of: tab.id)?.browser {
            browser.toaster.pop("Text copied", mark: "doc.on.doc", feedback: .success)
        }
    }

    func keepCurrent(as name: String) {
        guard let command, command.id == "ask" else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        // Kept once: the same words kept again are the command already there.
        guard !commands.contains(where: { $0.custom && $0.prompt == command.prompt }) else { return }
        commands.append(SelectionCommand(id: UUID().uuidString, name: cleanName,
                                         prompt: command.prompt, executor: "agent",
                                         custom: true))
        save()
    }

    func importRaycast(_ url: URL) throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let rows = value as? [[String: Any]]
            ?? (value as? [String: Any])?["commands"] as? [[String: Any]]
            ?? (value as? [String: Any])?["aiCommands"] as? [[String: Any]]
            ?? []
        var added = 0
        for row in rows {
            guard let name = row["name"] as? String, !name.isEmpty,
                  let prompt = row["prompt"] as? String, !prompt.isEmpty,
                  !prompt.contains("{argument") else { continue }
            if commands.contains(where: { $0.custom && $0.name == name && $0.prompt == prompt }) { continue }
            let output = (row["outputBehavior"] as? String ?? "").lowercased()
            commands.append(SelectionCommand(id: UUID().uuidString, name: name,
                                             prompt: prompt, executor: "agent", custom: true,
                                             applyImmediately: output.contains("replace"), result: "auto"))
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    func apply() {
        guard let snap = snapshot, !output.isEmpty, !replacing, receipt == nil, !insertionPending else { return }
        guard let web = tab?.builtPage else {
            applying = false
            error = "The page is gone. Copy the result instead."
            stage = .failed
            return
        }
        if command?.id == "map" {
            let query = snap.text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "https://maps.apple.com/?q=\(query)") { NSWorkspace.shared.open(url) }
            close()
            return
        }
        if command?.id == "call" {
            let phone = (snap.phone ?? snap.text).filter { $0.isNumber || $0 == "+" }
            if let url = URL(string: "tel:\(phone)") { NSWorkspace.shared.open(url) }
            close()
            return
        }
        if command?.id == "calendar", let date = snap.date {
            let current = generation
            Task {
                let store = EKEventStore()
                do {
                    guard try await Meetings.requestAccess(store) else {
                        guard generation == current else { return }
                        error = "Calendar access was not granted"
                        stage = .failed
                        return
                    }
                    guard generation == current, self.tab != nil else { return }
                    let event = EKEvent(eventStore: store)
                    event.title = snap.text
                    event.startDate = date
                    event.endDate = date.addingTimeInterval(3600)
                    event.notes = snap.url
                    event.calendar = store.defaultCalendarForNewEvents
                    try store.save(event, span: .thisEvent)
                    close()
                } catch {
                    guard generation == current else { return }
                    self.error = error.localizedDescription
                    stage = .failed
                }
            }
            return
        }
        if command?.result == "draft", let tab {
            AgentPage.run(tab, AgentPage.field, ["text": output]) { [weak self] result in
                if case .success(let value) = result, value as? Bool == true { self?.close() }
                else { self?.error = "The field is gone. Copy the text instead?"; self?.stage = .failed }
            }
            return
        }
        if !canReplace(snap) { applying = false; copyResult(); return }
        if docked { applying = true }
        insertionPending = true
        let current = generation
        let quoted = String(data: (try? JSONSerialization.data(withJSONObject: [output], options: .fragmentsAllowed)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let id = Self.javaScriptValue(snap.recordID ?? "")
        let script = "window.__yabApplySelection && window.__yabApplySelection(\(quoted)[0], \(id))"
        web.run(script, in: .client, frame: readFrame) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.insertionPending = false
                let value = (try? result.get()) as? String ?? "failed"
                if value == "ok" { self.landed() }
                else {
                    self.applying = false
                    if value == "failed" { self.copy() }
                    self.error = value == "changed" ? "The text changed while you looked. Copy it instead?"
                        : value == "gone" ? "The field is gone. Copy the text instead?"
                        : "This page didn't take the text. It's copied."
                    self.stage = .failed
                }
            }
        }
    }

    private static func javaScriptValue(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return "\(String(decoding: data, as: UTF8.self))[0]"
    }

    /// The longest selection the Mac's model is given whole.
    static let macLimit = 2_500

    func canReplace(_ snap: SelectionSnapshot) -> Bool {
        snap.editable && command?.id != "quote" && !["beside", "copy", "foot"].contains(command?.result ?? "auto")
    }

    enum SelectionError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
    }

    /// The frame the latest selection was read in, nil for the page's
    /// own: Replace puts the words back there.
    private var readFrame: PageFrame?

    /// The selection, wherever it is: the page's, a frame of its site's
    /// (readScript follows the caret into it), a shadow root's, or a
    /// frame of another site's, which only a read in that frame's own
    /// document reaches, as the agent's snapshot reads them. Of frames
    /// with words selected, the focused one; its rects are put on the page.
    private func read(_ web: any PageHandle, _ done: @escaping @MainActor (Any?) -> Void) {
        // Read without a gesture: 1.2 s after every click (maybeHint), a
        // gesture's end took the click's activation from the page (QuietScript).
        web.run(Self.readScript, in: .client, gesture: false) { [weak self, weak web] result in
            MainActor.assumeIsolated {
                if let value = try? result.get(), value is [String: Any] {
                    self?.readFrame = nil
                    done(value)
                    return
                }
                guard let web else { done(nil); return }
                web.childFrames { infos in
                    guard !infos.isEmpty else { done(nil); return }
                    var found: [(info: PageFrame, value: [String: Any])] = []
                    let group = DispatchGroup()
                    for info in infos {
                        group.enter()
                        web.run(Self.readScript, in: .client, frame: info, gesture: false) { result in
                            MainActor.assumeIsolated {
                                if let value = (try? result.get()) as? [String: Any] { found.append((info, value)) }
                                group.leave()
                            }
                        }
                    }
                    group.notify(queue: .main) {
                        MainActor.assumeIsolated {
                            guard let best = found.first(where: { $0.value["focused"] as? Bool == true }) ?? found.first else { done(nil); return }
                            Self.placeFrame(best.value, in: web) { [weak self] value in
                                self?.readFrame = best.info
                                done(value)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A frame's read moved onto the page: where its iframe's content
    /// box is, found by address, then size, then site (AgentPage.frame's
    /// way), added to the words' rect and box.
    private static func placeFrame(_ read: [String: Any], in web: any PageHandle, _ done: @escaping @MainActor ([String: Any]) -> Void) {
        let script = """
        const bare = (s) => String(s || '').split('#')[0];
        const all = [];
        (function look(doc, x, y) {
          for (const f of doc.querySelectorAll('iframe,frame')) {
            const r = f.getBoundingClientRect(), st = doc.defaultView.getComputedStyle(f);
            const cx = x + r.left + f.clientLeft + parseFloat(st.paddingLeft || 0);
            const cy = y + r.top + f.clientTop + parseFloat(st.paddingTop || 0);
            let inner = null; try { inner = f.contentDocument; } catch (e) {}
            if (inner) look(inner, cx, cy);
            else all.push({ src: f.src, x: cx, y: cy, w: f.clientWidth, h: f.clientHeight });
          }
        })(document, 0, 0);
        const near = (f) => Math.abs(f.w - w) < 3 && Math.abs(f.h - h) < 3;
        let origin = ''; try { origin = new URL(href).origin; } catch (e) {}
        const hit = all.find(f => f.src === href) || all.find(f => bare(f.src) === bare(href) && near(f))
          || all.find(f => bare(f.src) === bare(href)) || all.find(near)
          || all.find(f => { try { return origin && new URL(f.src).origin === origin; } catch (e) { return false; } });
        return hit ? { x: hit.x, y: hit.y } : null;
        """
        let arguments: [String: Any] = ["href": read["href"] as? String ?? "", "w": read["w"] as? Double ?? 0, "h": read["h"] as? Double ?? 0]
        web.call(script, arguments: arguments, in: .client, gesture: false) { result in
            MainActor.assumeIsolated {
                var placed = read
                if let at = (try? result.get()) as? [String: Any], let x = at["x"] as? Double, let y = at["y"] as? Double {
                    for key in ["rect", "box"] {
                        guard var r = placed[key] as? [String: Any] else { continue }
                        r["x"] = (r["x"] as? Double ?? 0) + x
                        r["y"] = (r["y"] as? Double ?? 0) + y
                        placed[key] = r
                    }
                } else {
                    // Nowhere on the page: the words are right, where they
                    // are isn't, and nothing is drawn over them.
                    placed["preciseRect"] = false
                }
                done(placed)
            }
        }
    }

    static let readScript = """
    (function () {
      \(DropFrame.ground)
      // The color itself, read from its words (yabColor); a pixel only
      // for colors outside sRGB.
      function solidColor(node, property) {
        for (let current = node; current; current = current.parentElement) {
          const rgba = yabColor(current.ownerDocument.defaultView.getComputedStyle(current)[property], current.ownerDocument);
          if (!rgba || rgba[3] < 240) continue;
          return rgba.slice(0, 3).map(v => v.toString(16).padStart(2, '0')).join('');
        }
        return property === 'backgroundColor' ? 'ffffff' : '171717';
      }
      // Words selected inside a shadow root: the document's own range
      // stops at the host, collapsed, and only the composed one, asked
      // with the open roots, reaches them.
      function chosen(doc, s) {
        if (!s || !s.rangeCount) return null;
        const flat = s.getRangeAt(0);
        if (!s.isCollapsed && flat.toString().trim()) return flat.cloneRange();
        if (!s.getComposedRanges) return null;
        // The open roots, looked for over at most 30000 elements: a caret
        // on a huge page costs a few milliseconds, never more.
        const roots = []; let seen = 0;
        const walk = (w) => { for (let n = w.nextNode(); n && seen++ < 30000; n = w.nextNode()) if (n.shadowRoot) {
          roots.push(n.shadowRoot); walk(doc.createTreeWalker(n.shadowRoot, NodeFilter.SHOW_ELEMENT)); } };
        walk(doc.createTreeWalker(doc, NodeFilter.SHOW_ELEMENT));
        if (!roots.length) return null;
        let ranges;
        try { ranges = s.getComposedRanges({ shadowRoots: roots }); }
        catch (e) { try { ranges = s.getComposedRanges(...roots); } catch (e2) { return null; } }
        const at = ranges && ranges[0];
        if (!at || at.collapsed) return null;
        const range = doc.createRange();
        try { range.setStart(at.startContainer, at.startOffset); range.setEnd(at.endContainer, at.endOffset); } catch (e) { return null; }
        return range.collapsed ? null : range;
      }
      function read(doc, offsetX, offsetY) {
        let el = doc.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
        if (el && /^(IFRAME|FRAME)$/.test(el.tagName)) {
          try { if (el.contentDocument) { const r = el.getBoundingClientRect(); return read(el.contentDocument, offsetX + r.left, offsetY + r.top); } } catch (e) { return null; }
        }
        if (el && el.tagName === 'INPUT' && el.type === 'password') return null;
        let text = '', editable = false, start = 0, end = 0, range = null, around = '', rect;
        var preciseRect = true;
        if (el && (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && /^(text|search|email|url|)$/.test(el.type)))) {
          start = el.selectionStart; end = el.selectionEnd;
          if (typeof start === 'number' && end > start) {
            text = el.value.slice(start, end);
            around = el.value.slice(Math.max(0, start - 600), start) + el.value.slice(end, Math.min(el.value.length, end + 600));
            editable = !el.readOnly && !el.disabled; rect = el.getBoundingClientRect();
            if (start > 10000 || text.length > 2000) {
              preciseRect = false;
            } else if (el.tagName === 'INPUT') {
              const style = doc.defaultView.getComputedStyle(el);
              const canvas = doc.createElement('canvas'); const context = canvas.getContext('2d');
              context.font = style.font;
              const x = rect.x + parseFloat(style.paddingLeft || 0) + context.measureText(el.value.slice(0, start)).width - el.scrollLeft;
              const width = Math.max(3, context.measureText(text).width);
              const size = parseFloat(style.fontSize || 13);
              rect = { x, y: rect.y + (rect.height - size) / 2, width, height: size + 3 };
            } else {
              const style = doc.defaultView.getComputedStyle(el);
              const mirror = doc.createElement('div');
              const props = ['boxSizing','width','padding','borderWidth','borderStyle','fontFamily','fontSize',
                'fontWeight','lineHeight','letterSpacing','wordSpacing','textTransform','textIndent','tabSize'];
              for (const prop of props) mirror.style[prop] = style[prop];
              mirror.style.cssText += ';position:fixed;visibility:hidden;pointer-events:none;white-space:pre-wrap;overflow-wrap:break-word;top:' +
                (rect.top - el.scrollTop) + 'px;left:' + rect.left + 'px;max-width:none;';
              mirror.append(doc.createTextNode(el.value.slice(0, start)));
              const chosen = doc.createElement('span'); chosen.textContent = text;
              mirror.append(chosen); doc.body.append(mirror);
              const found = chosen.getBoundingClientRect();
              const field = el.getBoundingClientRect();
              if (found.width > 0 && found.bottom > field.top && found.top < field.bottom) {
                rect = {x: Math.max(field.left, found.left), y: Math.max(field.top, found.top),
                  width: Math.min(field.right, found.right) - Math.max(field.left, found.left),
                  height: Math.min(field.bottom, found.bottom) - Math.max(field.top, found.top)};
              }
              mirror.remove();
            }
          } else return null;
        }
        if (!text) {
          range = chosen(doc, doc.getSelection()); if (!range) return null;
          text = range.toString();
          if (!text.trim()) return null;
          const root = range.commonAncestorContainer.nodeType === 1 ? range.commonAncestorContainer : range.commonAncestorContainer.parentElement;
          editable = !!root?.closest?.('[contenteditable="true"],[contenteditable=""],[contenteditable="plaintext-only"],[role="textbox"]:not([aria-readonly="true"])');
          around = root?.parentElement?.textContent?.slice(0, 1200) || text;
          rect = range.getBoundingClientRect();
        }
        if (!text.trim() || !rect) return null;
        const root = range ? (range.commonAncestorContainer.nodeType === 1 ? range.commonAncestorContainer : range.commonAncestorContainer.parentElement) : el;
        const code = !!root?.closest?.('pre,code');
        const style = root ? doc.defaultView.getComputedStyle(root) : null;
        const truncated = text.length > 20000;
        // The block the words wrap in, inside its padding: the field, or
        // the paragraph round a selection on the page.
        let box = null;
        for (let n = root; n && n.nodeType === 1; n = n.parentElement) {
          const s = doc.defaultView.getComputedStyle(n);
          if (s.display === 'inline' || s.display === 'contents') continue;
          const r = n.getBoundingClientRect();
          const left = parseFloat(s.paddingLeft || 0) + parseFloat(s.borderLeftWidth || 0);
          const top = parseFloat(s.paddingTop || 0) + parseFloat(s.borderTopWidth || 0);
          box = { x: r.left + left + offsetX, y: r.top + top + offsetY,
            width: r.width - left - parseFloat(s.paddingRight || 0) - parseFloat(s.borderRightWidth || 0),
            height: r.height - top - parseFloat(s.paddingBottom || 0) - parseFloat(s.borderBottomWidth || 0) };
          break;
        }
        const documentID = window.__yabSelectionDocument ||= String(Date.now()) + ':' + Math.random();
        const recordID = documentID + ':' + String(window.__yabSelectionSerial = (window.__yabSelectionSerial || 0) + 1);
        if (!window.__yabSelectionRevisionInstalled) {
          window.__yabSelectionRevisionInstalled = true;
          window.__yabSelectionRevision = 0;
          doc.addEventListener('input', () => { window.__yabSelectionRevision++; }, true);
        }
        const editor = range && editable ? root?.closest?.('[contenteditable="true"],[contenteditable=""],[contenteditable="plaintext-only"],[role="textbox"]') : null;
        let editorText = null, textStart = 0;
        if (editor && editor.contains(range.startContainer) && editor.contains(range.endContainer)) {
          editorText = editor.textContent;
          const prefix = doc.createRange(); prefix.selectNodeContents(editor);
          prefix.setEnd(range.startContainer, range.startOffset);
          textStart = prefix.toString().length;
        }
        window.__yabSelectionRecord = truncated ? null : { el, start, end, range, text, editable, root, recordID, editor, editorText, textStart };
        window.__yabApplySelection = function (replacement, expectedID) {
          const kept = window.__yabSelectionRecord;
          if (!kept || (kept.el && !kept.el.isConnected)) return 'gone';
          if (expectedID && expectedID !== kept.recordID) return 'changed';
          if (!kept.editable) return 'failed';
          if (kept.range) {
            // Rich editors rebuild text nodes on blur. A live Range then
            // collapses even though the draft has not changed (#1824).
            // Recover its exact text offsets only in the same, unchanged
            // editor; an edited or replaced draft must still be refused.
            if (kept.range.toString() !== kept.text && kept.editor?.isConnected &&
                kept.editorText !== null && kept.editor.textContent === kept.editorText) {
              const walk = doc.createTreeWalker(kept.editor, NodeFilter.SHOW_TEXT);
              const restored = doc.createRange();
              let offset = 0, began = false, ended = false;
              for (let node = walk.nextNode(); node; node = walk.nextNode()) {
                const limit = offset + node.length;
                if (!began && kept.textStart <= limit) {
                  restored.setStart(node, kept.textStart - offset); began = true;
                }
                if (began && kept.textStart + kept.text.length <= limit) {
                  restored.setEnd(node, kept.textStart + kept.text.length - offset); ended = true; break;
                }
                offset = limit;
              }
              if (ended && restored.toString() === kept.text) kept.range = restored;
            }
            if (!kept.range.startContainer.isConnected || !kept.range.endContainer.isConnected) return 'gone';
            if (kept.range.toString() !== kept.text) return 'changed';
            const editor = kept.editor;
            if (!editor || !editor.isConnected) return 'gone';
            const before = editor.innerHTML;
            editor.focus();
            const s = doc.getSelection(); s.removeAllRanges(); s.addRange(kept.range);
            if (doc.execCommand('insertText', false, replacement)) {
              const after = editor.innerHTML, revision = window.__yabSelectionRevision;
              window.__yabUndoSelection = function (id) {
                if (id && id !== kept.recordID) return 'changed';
                if (!editor.isConnected) return 'gone';
                if (editor.innerHTML !== after || window.__yabSelectionRevision !== revision) return 'changed';
                editor.focus();
                if (!doc.execCommand('undo') || editor.innerHTML !== before) return 'failed';
                window.__yabUndoSelection = null;
                return 'ok';
              };
              return 'ok';
            }
            return 'failed';
          }
          if (kept.el.value.slice(kept.start, kept.end) !== kept.text) return 'changed';
          if (kept.el.readOnly || kept.el.disabled) return 'failed';
          const before = kept.el.value;
          kept.el.focus(); kept.el.setSelectionRange(kept.start, kept.end);
          const native = doc.execCommand('insertText', false, replacement)
            && kept.el.value.slice(kept.start, kept.start + replacement.length) === replacement;
          if (!native) {
            kept.el.setRangeText(replacement, kept.start, kept.end, 'end');
            kept.el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: replacement }));
          }
          const after = kept.el.value, revision = window.__yabSelectionRevision;
          window.__yabUndoSelection = function (id) {
            if (id && id !== kept.recordID) return 'changed';
            if (!kept.el.isConnected) return 'gone';
            if (kept.el.value !== after || kept.el.readOnly || kept.el.disabled || window.__yabSelectionRevision !== revision) return 'changed';
            kept.el.focus();
            // WebKit can merge insertText with typing that preceded this
            // command. Restore only our captured range, leaving that history alone.
            kept.el.setRangeText(kept.text, kept.start, kept.start + replacement.length, 'select');
            kept.el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'historyUndo' }));
            if (kept.el.value !== before) return 'failed';
            window.__yabUndoSelection = null;
            return 'ok';
          };
          return 'ok';
        };
        return { text: truncated ? text.slice(0, 20000) : text, around, editable: editable && !truncated, recordID,
          preciseRect, truncated, code, fontSize: parseFloat(style?.fontSize || 13),
          lineHeight: parseFloat(style?.lineHeight) || parseFloat(style?.fontSize || 13) * 1.2,
          fontFamily: style?.fontFamily?.split(',')[0]?.replace(/["']/g, '').trim() || 'Arial',
          foreground: solidColor(root, 'color'), ground: solidColor(root, 'backgroundColor'),
          dark: yabGround(root), box,
          rect: { x: rect.x + offsetX, y: rect.y + offsetY, width: rect.width, height: rect.height } };
      }
      const found = read(document, 0, 0);
      // Where it was read, for the page to place a frame's words on it.
      if (found) Object.assign(found, { href: location.href, w: innerWidth, h: innerHeight, focused: document.hasFocus() });
      return found;
    })()
    """
}
