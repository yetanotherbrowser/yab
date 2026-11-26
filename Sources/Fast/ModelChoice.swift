import AppKit
import SwiftUI

// Which model does a piece of work: one list you
// can search, the models grouped by the plan they come from and each saying
// which agent runs it, so picking a model picks Claude Code or Codex too.
// Claude's are Claude Code's aliases, each following the newest release;
// Codex's are read from the list Codex keeps of what your plan has
// (~/.codex/models_cache.json), so they are the ones it takes today.
//
// Each kind of work has a default in Settings › AI › Models (ModelDefaults):
// tasks, and commands on selected text. A command can have a model of its
// own (SelectionCommand.model), picked in its editor with the same field.

/// A model an agent can be started on, or this Mac's own.
struct AgentModel: Identifiable, Hashable {
    /// A plan's CLI (AgentPlan), or "mac".
    let cli: String
    /// What the agent is told (`--model`, `-m`); "" for the Mac's.
    let model: String
    let name: String
    let about: String
    /// The reasoning efforts it takes, least first.
    let efforts: [String]
    /// What its agent says of it, for the picker's details: how much it
    /// reads at once in tokens, whether it sees images, a fast mode.
    var context: Int? = nil
    var vision = false
    var fast = false

    var id: String { cli + ":" + model }
}

@MainActor
enum AgentModels {
    static let mac = AgentModel(cli: "mac", model: "", name: "Apple Intelligence",
                                about: "On this Mac: free, private, for short text. Longer text goes to the Commands default.",
                                efforts: [])

    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    static let claude: [AgentModel] = [
        AgentModel(cli: "claude", model: "fable", name: "Claude Fable", about: "The newest and most capable.", efforts: claudeEfforts, context: 1_000_000, vision: true),
        AgentModel(cli: "claude", model: "opus", name: "Claude Opus", about: "For long, hard tasks.", efforts: claudeEfforts, context: 1_000_000, vision: true),
        AgentModel(cli: "claude", model: "sonnet", name: "Claude Sonnet", about: "Fast and capable, for most work.", efforts: claudeEfforts, context: 1_000_000, vision: true),
        AgentModel(cli: "claude", model: "haiku", name: "Claude Haiku", about: "The fastest, for short text.", efforts: claudeEfforts, context: 1_000_000, vision: true),
    ]

    private static var codexRead: (at: Date, models: [AgentModel])?

    /// What the Codex that runs tasks can be started on: the list asked of
    /// that copy when a task last started (CodexCatalog), or, until one
    /// has, the one Codex keeps (~/.codex/models_cache.json), which
    /// whichever copy fetched it last wrote; a model in it this copy can't
    /// take is swapped at the start (ModelFit). A list on screen never runs
    /// Codex to ask. Read again at most every half minute.
    static func codex() -> [AgentModel] {
        if let binary = Shell.cached?.codex, let catalog = CodexCatalog.cached(binary, env: Shell.cached?.env ?? [:]) {
            return catalog.shown
        }
        if let codexRead, codexRead.at.timeIntervalSinceNow > -30 { return codexRead.models }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let file = URL(fileURLWithPath: home).appendingPathComponent(".codex/models_cache.json")
        var models: [AgentModel] = []
        if let data = try? Data(contentsOf: file),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rows = object["models"] as? [[String: Any]] {
            models = codexModels(rows)
        }
        codexRead = (Date(), models)
        return models
    }

    /// Codex's rows as the picker shows them: the listed ones, in its order.
    static func codexModels(_ rows: [[String: Any]]) -> [AgentModel] {
        rows.filter { ($0["visibility"] as? String ?? "list") == "list" }
            .sorted { ($0["priority"] as? Int ?? 99) < ($1["priority"] as? Int ?? 99) }
            .compactMap { row in
                guard let slug = row["slug"] as? String, !slug.isEmpty else { return nil }
                let efforts = (row["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
                return AgentModel(cli: "codex", model: slug, name: title(row["display_name"] as? String ?? slug),
                                  about: row["description"] as? String ?? "", efforts: efforts,
                                  context: row["context_window"] as? Int,
                                  vision: (row["input_modalities"] as? [String] ?? []).contains("image"),
                                  fast: !(row["additional_speed_tiers"] as? [String] ?? []).isEmpty)
            }
    }

    /// A model's name as the picker says it, or its id.
    static func name(_ cli: String, _ model: String) -> String {
        if let named = find(cli, model)?.name { return named }
        guard cli == "codex" else { return model }
        // "gpt-6.1-sol": "GPT-6.1 Sol".
        return title(model.split(separator: "-").enumerated().map { $0.offset == 0 ? $0.element.uppercased() : $0.element.capitalized }.joined(separator: "-"))
    }

    /// "GPT-6-Astra" written for people: "GPT-6 Astra".
    static func title(_ name: String) -> String {
        let parts = name.split(separator: "-").map(String.init)
        guard parts.count > 2 else { return name }
        return parts[0] + "-" + parts[1] + " " + parts.dropFirst(2).joined(separator: " ")
    }

    static func find(_ cli: String?, _ model: String?) -> AgentModel? {
        guard let cli else { return nil }
        if cli == "mac" { return mac }
        // Cursor with no model of its own runs on Auto, its plan's default.
        if cli == "cursor" { return CursorRunner.models.first { $0.model == (model.flatMap { $0.isEmpty ? nil : $0 } ?? "auto") } }
        guard let model else { return nil }
        let list = AgentPlan.of(cli)?.models ?? []
        if let exact = list.first(where: { $0.model == model }) { return exact }
        // Legacy Gemini choices saved effort-pinned IDs (e.g. "gemini-4-neon-high")
        // before ACP split models from thinking levels. Match their base family.
        if cli == "gemini",
           let pinned = ["low", "medium", "high", "xhigh", "max"].first(where: { model.hasSuffix("-" + $0) }) {
            let base = String(model.dropLast(pinned.count + 1))
            if let family = list.first(where: { $0.model == base }) { return family }
        }
        return nil
    }

    /// Whether this Mac has the agent; not looked for yet counts as yes.
    static func here(_ cli: String) -> Bool {
        guard let plan = AgentPlan.of(cli) else { return true }
        // Gemini is here once signed in (GeminiAccount); Cursor once
        // connected: their models are their account's.
        if cli == "gemini" { return GeminiAccount.shared.ready }
        // Before the login shell has been asked (just after launch), a
        // connected Cursor counts as here, as the others do: else the first
        // task after a restart fell to Claude (evals/agent-providers).
        if !plan.listedAway { return CursorRunner.connected && (Shell.cached.map { $0.cursor != nil } ?? true) }
        if let assumed = Agents.assumedInTests, Store.testing { return assumed }
        return AgentLaunch.here(cli) ?? true
    }

    static func agentName(_ cli: String) -> String { AgentSetupModel.name(cli) }

    static func effortTitle(_ effort: String) -> String {
        switch effort {
        case "xhigh": "Extra high"
        default: effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }
}

/// What a kind of work, or a command, runs on. No agent means the default:
/// for a kind of work, yours on its own model ("Auto"); for a command, the
/// Commands default.
struct ModelChoice: Equatable {
    var cli: String?
    var model: String?
    var effort: String?
}

/// The default model for each kind of work, kept in the settings.
@MainActor
final class ModelDefaults: ObservableObject {
    static let shared = ModelDefaults()

    enum Work: String, CaseIterable {
        case tasks, chats, commands, drafts

        var title: String {
            switch self {
            case .tasks: "Tasks"
            case .chats: "Chats and ⌘J"
            case .commands: "Commands"
            case .drafts: "Form drafts"
            }
        }
        var detail: String {
            switch self {
            case .tasks: "What you ask for in the address bar, and routines."
            case .chats: "New chats and questions you ask with ⌘J."
            case .commands: "Commands on selected text this Mac's model can't do."
            case .drafts: "Answers to a form's questions, and mail replies written ahead."
            }
        }
        /// The plans its list offers: every one, those that can't do this
        /// kind of work greyed with why (`refusal`).
        @MainActor var plans: [String] { AgentPlan.clis }

        /// Why a plan can't do this kind of work, for its list; nil when it
        /// can. Every plan writes drafts, in one quick run with no tools
        /// (PlanText), and every plan with Yab's tools takes tasks.
        func refusal(_ cli: String) -> String? {
            guard let plan = AgentPlan.of(cli) else { return nil }
            if self == .tasks, !plan.tools { return "\(plan.name) can't use Yab's tools in tasks yet." }
            return nil
        }
    }

    /// Who writes form drafts: the plan Form drafts names when it is
    /// connected to write (`connected`, PlanText.agents, yours first), else
    /// the first of those; nil when none is, so nothing runs on a plan you
    /// didn't connect.
    nonisolated static func draftWriter(chosen: String?, connected: [String]) -> String? {
        if let chosen, connected.contains(chosen) { return chosen }
        return connected.first
    }

    /// What Auto says it runs on, beside it in the list: the drafts'
    /// writer and model, or for other work your plan.
    static func autoDetail(_ work: Work, writer: String?, preferred: String) -> String {
        guard work == .drafts else { return AgentSetupModel.name(preferred) }
        switch writer {
        case "claude": return "Claude Sonnet"
        case nil: return "Not connected"
        case let other?: return AgentSetupModel.name(other)
        }
    }

    /// What Auto's foot says when it can't run at all, else nil.
    nonisolated static func autoTrouble(_ work: Work, writer: String?) -> String? {
        work == .drafts && writer == nil ? "Form drafts need a plan connected in Settings \u{203A} AI." : nil
    }

    @Published private var choices: [Work: ModelChoice] = [:]
    /// Models left out of the lists (Models in lists), by `AgentModel.id`.
    @Published var hidden: Set<String> {
        didSet { Store.settings.set(Array(hidden).sorted(), forKey: "models.hidden") }
    }

    init() {
        hidden = Set(Store.settings.stringArray(forKey: "models.hidden") ?? [])
        for work in Work.allCases {
            let key = "models." + work.rawValue
            choices[work] = ModelChoice(cli: Store.settings.string(forKey: key + ".cli"),
                                        model: Store.settings.string(forKey: key + ".model"),
                                        effort: Store.settings.string(forKey: key + ".effort"))
        }
        // Chats used the Tasks default before they had one of their own.
        // Migrate it once; choosing Auto later must stay Auto after restart.
        if !Store.settings.bool(forKey: "models.chats.configured") {
            // Whoever put the Tasks default there put this one there too.
            let source = Store.settings.string(forKey: Self.sourceKey(.tasks))
            self[.chats] = choices[.tasks] ?? ModelChoice()
            Store.settings.set(source, forKey: Self.sourceKey(.chats))
        }
    }

    subscript(work: Work) -> ModelChoice {
        get { choices[work] ?? ModelChoice() }
        set {
            choices[work] = newValue
            if work == .chats { Store.settings.set(true, forKey: "models.chats.configured") }
            let key = "models." + work.rawValue
            Store.settings.set(Self.chosenByHand, forKey: Self.sourceKey(work))
            Store.settings.set(newValue.cli, forKey: key + ".cli")
            Store.settings.set(newValue.model, forKey: key + ".model")
            Store.settings.set(newValue.effort, forKey: key + ".effort")
            // Drafts keep one Claude Code running: the next starts on this.
            if work == .drafts { FormDraft.shared.stop() }
        }
    }

    private static let chosenByHand = "hand", filledByConnect = "connect"
    private static func sourceKey(_ work: Work) -> String { "models." + work.rawValue + ".source" }

    /// A default you never picked: filled by an earlier first connect, or
    /// Auto as it came. A plan stored with no source is from before sources
    /// were kept and counts as yours, since nothing can tell.
    private func untouched(_ work: Work) -> Bool {
        switch Store.settings.string(forKey: Self.sourceKey(work)) {
        case Self.filledByConnect: true
        case nil: self[work].cli == nil
        default: false
        }
    }

    /// A plan just connected. Beside another connected plan it changes no
    /// default, Auto included: those already run on a plan you have. As the
    /// first plan it fills the defaults you never picked, so Yab starts on
    /// the plan you came with; removing it and connecting again moves
    /// nothing you chose (the report of 2026-10-30).
    func useProvider(_ cli: String) {
        guard let plan = AgentPlan.of(cli),
              !AgentPlan.all.contains(where: { $0.cli != cli && AgentSetup.connected($0.cli) }) else { return }
        for work in [Work.chats, .commands, .tasks] where untouched(work) {
            // A plan without tools leaves Tasks on Auto, which says who stands in.
            self[work] = work != .tasks || plan.tools ? ModelChoice(cli: cli) : ModelChoice()
            Store.settings.set(Self.filledByConnect, forKey: Self.sourceKey(work))
        }
    }

    func binding(_ work: Work) -> Binding<ModelChoice> {
        Binding(get: { self[work] }, set: { self[work] = $0 })
    }

    /// What to start for this kind of work: its default's agent and model
    /// when that agent is here, else yours on its own model.
    func pick(_ work: Work) -> (cli: String, model: String?, effort: String?) {
        let choice = self[work]
        // Gemini chosen stays Gemini: not signed in, its run fails saying
        // so, never answered on another plan.
        if choice.cli == "gemini" { return ("gemini", choice.model, choice.effort) }
        if let cli = choice.cli, cli != "mac", AgentModels.here(cli), !Self.outInFavorOfAnother(cli) {
            return (cli, choice.model, choice.effort)
        }
        return (automatic(work), nil, choice.effort)
    }

    /// A chosen plan you removed, with another connected: that one does the
    /// work and your choice waits, back the moment its plan is. Installed
    /// isn't enough, its run would only be refused (ProviderConsent).
    private static func outInFavorOfAnother(_ cli: String) -> Bool {
        !AgentSetup.connected(cli) && AgentPlan.all.contains { AgentSetup.connected($0.cli) }
    }

    /// Text work may use a signed-in Gemini plan on its own. Tasks follow
    /// your provider too (tasksRoute): Gemini's go to a plan with tools when
    /// one is here, and say so.
    func automatic(_ work: Work) -> String {
        if work == .tasks { return tasksRoute.cli }
        if work == .chats || work == .commands,
           GeminiAccount.shared.ready,
           !AgentPlan.all.contains(where: { $0.cli != "gemini" && AgentSetupModel.shared.connected($0.cli) }) {
            return "gemini"
        }
        return Agents.preferred
    }

    /// Who a task runs on when Tasks is Auto, and the line its chat opens
    /// with when that isn't your provider. `text` is your provider, the
    /// Chats default's plan. Gemini and Cursor, yours,
    /// take your tasks with Yab's tools as Claude and ChatGPT do (Cursor
    /// once connected here). A build whose Gemini can't use Yab's tools
    /// (`geminiTools` false) sends its tasks to `preferred` when a plan
    /// with tools is here, saying why, else Gemini answers without them
    /// and says that. Never silently Claude.
    nonisolated static func autoTasks(text: String, preferred: String, toolsHere: Bool,
                                      geminiTools: Bool = GeminiSupport.toolsProven,
                                      cursorHere: Bool = false) -> (cli: String, line: String?) {
        if text == "cursor", cursorHere { return ("cursor", nil) }
        guard text == "gemini" else { return (preferred, nil) }
        if geminiTools { return ("gemini", nil) }
        guard toolsHere else { return ("gemini", geminiAloneLine) }
        return (preferred, "Gemini can\u{2019}t use Yab\u{2019}s tools in tasks yet, so \(AgentSetupModel.name(preferred)) took this task.")
    }

    nonisolated static let geminiAloneLine = "Gemini can\u{2019}t use Yab\u{2019}s tools in tasks yet, so it answered without your tabs. "
        + "Connect Claude, ChatGPT or Cursor in Settings \u{203A} AI for tasks done in tabs."
    /// A task nobody watches (a routine, a boost, getting to know you) that
    /// only Gemini could take: it fails saying so rather than answering blind.
    nonisolated static let geminiUnattended = "Gemini can\u{2019}t use Yab\u{2019}s tools yet, so it can\u{2019}t do this on its own. "
        + "Connect Claude, ChatGPT or Cursor in Settings \u{203A} AI for it."

    /// A plan that can use Yab's tools is on this Mac: connected in Yab, or
    /// its CLI found (not looked for yet counts as yes), as Agents.preferred
    /// would start it. Cursor only once connected.
    static var toolPlanHere: Bool {
        if Store.testing, let given = toolPlanHereInTests { return given }
        let found = Shell.cached
        return AgentPlan.all.contains { plan in
            plan.tools && AgentSetup.connected(plan.cli)
                && (found.map { AgentSetupModel.binary(plan.cli, in: $0) != nil } ?? true)
        }
    }
    /// A unit test's say on `toolPlanHere`; nil asks the Mac.
    static var toolPlanHereInTests: Bool?

    /// `autoTasks` for this Mac, your provider as the Chats default picks it.
    var tasksRoute: (cli: String, line: String?) {
        Self.autoTasks(text: pick(.chats).cli, preferred: Agents.preferred, toolsHere: Self.toolPlanHere,
                       cursorHere: CursorRunner.connected && AgentModels.here("cursor"))
    }

    /// The line a new task on `cli` opens with when Auto put it there in
    /// place of your provider; nil when Tasks names a plan that is here.
    func tasksLine(_ cli: String) -> String? {
        if let chosen = self[.tasks].cli, chosen != "mac", chosen == "gemini" || AgentModels.here(chosen) { return nil }
        let route = tasksRoute
        return route.cli == cli ? route.line : nil
    }

    /// What the Tasks row says under Auto when it doesn't run your provider.
    var tasksNote: String? {
        guard self[.tasks].cli == nil else { return nil }
        let route = tasksRoute
        guard route.line != nil else { return nil }
        return route.cli == "gemini" ? "Gemini can\u{2019}t use Yab\u{2019}s tools yet, so it answers tasks without your tabs."
            : "Gemini can\u{2019}t use Yab\u{2019}s tools yet, so tasks run on \(AgentSetupModel.name(route.cli))."
    }

    /// Where Gemini's tasks would go if it were chosen now, for Connect's
    /// words: the plan with tools that stands in, or nil for Gemini itself.
    static var geminiTasksGoTo: String? {
        let route = autoTasks(text: "gemini", preferred: Agents.preferred, toolsHere: toolPlanHere)
        return route.cli == "gemini" ? nil : route.cli
    }

    /// `pick` as it runs now: the default stays yours, but while its plan
    /// is out of room (as Yab last heard) and the other plan is here,
    /// connected and has some, the other's, on its own model, as a new chat
    /// starts there (Agents.choose). The field's rows and the answer's
    /// header say this one, so "Ask Claude" isn't said when ChatGPT answers;
    /// with room again, the default is back.
    func pickNow(_ work: Work) -> (cli: String, model: String?, effort: String?) {
        let pick = pick(work)
        let plans = PlanAccounts.shared
        guard pick.cli == "claude" || pick.cli == "codex",
              Agents.startsOnOther(pick.cli, room: { plans.hasRoom($0) }, here: AgentModels.here, connected: AgentSetup.connected)
        else { return pick }
        let effort = pick.effort.flatMap { ["low", "medium", "high"].contains($0) ? $0 : nil }
        return (Agents.other(pick.cli), nil, effort)
    }

    /// "Claude Haiku", or "Auto" when yours picks.
    func name(_ work: Work) -> String {
        ModelField.title(self[work]) ?? "Auto"
    }
}

/// The field a model is chosen in: the model and the agent that runs it,
/// and the list on a click.
struct ModelField: View {
    @Binding var choice: ModelChoice
    /// The first row, for no model of its own: "Auto" for a kind of work,
    /// "Default" for a command.
    let automatic: (title: String, detail: String)
    /// Whose default "Default" follows: a routine's is the Tasks one.
    var follows = ModelDefaults.Work.commands
    /// A command's list also offers this Mac's own model.
    var offersMac = false
    /// The plans the list offers.
    var plans = AgentPlan.clis
    /// Whose list it is, so a plan that can't do that work is greyed.
    var work: ModelDefaults.Work?
    /// What Auto's foot says when it can't run (`autoTrouble`).
    var trouble: String?
    var width = ChoiceFace<EmptyView>.width
    /// A table's cell rather than a button: the words bare at rest, a
    /// hairline round them under the pointer (TableCell), as Commands'
    /// rows and Raycast's have it.
    var cell: String?
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Group {
            if let cell {
                Button { open.toggle() } label: {
                    HStack(spacing: 6) {
                        if choice.cli != nil { ModelMark(cli: choice.cli) }
                        Text(cell)
                            .lineLimit(1)
                            .foregroundStyle(choice.cli == nil ? .secondary : .primary)
                        Spacer(minLength: 0)
                        Symbol("chevron.up.chevron.down", size: 8, weight: .semibold) // design: MenuCell's own
                            .foregroundStyle(.secondary)
                            .opacity(hovering || open ? 1 : 0)
                    }
                    .modifier(TableCell(width: width, hovering: hovering, active: open))
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
            } else {
                Button { open.toggle() } label: {
                    ChoiceFace(title: ModelField.title(choice) ?? automatic.title, width: width) {
                        ModelMark(cli: choice.cli)
                    }
                }
                .buttonStyle(.yab(.secondary, .small))
            }
        }
        .fixedSize()
        .accessibilityLabel("Model")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ModelList(choice: choice, automatic: automatic, follows: follows, offersMac: offersMac, plans: plans,
                      work: work, trouble: trouble) { picked in
                // A new model keeps the effort only if it takes it.
                var picked = picked
                if let effort = choice.effort, let model = AgentModels.find(picked.cli, picked.model), model.efforts.contains(effort) {
                    picked.effort = effort
                } else if picked.cli == nil {
                    picked.effort = choice.effort
                }
                choice = picked
                open = false
            } close: {
                open = false
            }
        }
    }
}

/// The reasoning efforts the chosen model takes, and Auto for its own.
struct EffortField: View {
    @Binding var choice: ModelChoice
    var width = ChoiceFace<EmptyView>.width

    var body: some View {
        let efforts = AgentModels.find(choice.cli, choice.model)?.efforts
            ?? (choice.cli == "mac" ? [] : AgentModels.claudeEfforts)
        ChoiceDrop(title: "Reasoning effort",
                   options: [DropOption(title: "Auto", value: String?.none)]
                       + efforts.map { DropOption(title: AgentModels.effortTitle($0), value: Optional($0)) },
                   selection: $choice.effort, width: width,
                   face: (choice.effort.map(AgentModels.effortTitle) ?? "Auto") + " effort") {
            Symbol("gauge.with.dots.needle.33percent", size: 11).frame(width: 14, height: 14)
        }
        .disabled(efforts.isEmpty)
        .accessibilityLabel("Reasoning effort")
    }
}

/// The face the model and effort fields share, Raycast's: a mark, the
/// choice, ⌃⌄ at the end, one width so they line up stacked.
struct ChoiceFace<Mark: View>: View {
    static var width: CGFloat { 148 }
    let title: String
    var width: CGFloat = 148
    @ViewBuilder var mark: () -> Mark

    var body: some View {
        HStack(spacing: 6) {
            mark()
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 0)
            Symbol("chevron.up.chevron.down", size: 8, weight: .semibold) // design: the size of MenuCell's own
                .foregroundStyle(.secondary)
        }
        .frame(width: width)
    }
}

/// One of a few choices, in the model field's face: the command editor's
/// Result and Shows for, so every field down its side looks one way.
struct ChoiceMenu<Value: Hashable>: View {
    let title: String
    let options: [(title: String, value: Value)]
    @Binding var selection: Value
    var width = ChoiceFace<EmptyView>.width

    var body: some View {
        ChoiceDrop(title: title, options: options.map { DropOption(title: $0.title, value: $0.value) },
                   selection: $selection, width: width) { EmptyView() }
    }
}

/// A ChoiceFace whose list is Settings' own (DropPopup), as Search with's
/// and Tab icons' are, not the system's menu.
struct ChoiceDrop<Value: Hashable, Mark: View>: View {
    let title: String
    let options: [DropOption<Value>]
    @Binding var selection: Value
    var width = ChoiceFace<EmptyView>.width
    /// The face's words, when not the chosen answer's own.
    var face: String? = nil
    @ViewBuilder var mark: () -> Mark
    @State private var place = DropAnchor.Place()

    private var chosen: String { options.first { $0.value == selection }?.title ?? "" }

    var body: some View {
        Button(action: open) {
            ChoiceFace(title: face ?? chosen, width: width, mark: mark)
        }
        .buttonStyle(.yab(.secondary, .small))
        // Under the button: where the list hangs from, never the press.
        .background(DropAnchor(place: place, title: title, value: chosen, press: open, hover: { _ in }))
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(chosen)
    }

    private func open() {
        guard let view = place.view, view.window != nil else { return }
        // The press that just put the list away opens nothing.
        if DropPopup.closed(from: view) { return }
        let values = options.map(\.value)
        let list = DropList(options: options.map { DropList.Line(title: $0.title, picture: $0.picture, note: $0.note) },
                            chosen: values.firstIndex(of: selection) ?? 0, divideBefore: nil, inset: DropFace.inset)
        DropPopup.show(list, under: view) { index in
            if let index, values.indices.contains(index) { selection = values[index] }
        }
    }
}

/// The agent's own mark beside a model; this Mac's, or a spark for Auto.
struct ModelMark: View {
    let cli: String?

    var body: some View {
        switch cli {
        case "mac": Symbol("brand.apple.intelligence", size: 13).frame(width: 14, height: 14)
        case let cli? where AgentPlan.isPlan(cli): AgentMark(cli: cli, side: 14)
        default: Symbol("sparkles", size: 11).frame(width: 14, height: 14)
        }
    }
}

/// The list: a search field, the models by plan, and what the one under
/// the pointer is, at its foot.
private struct ModelList: View {
    @ObservedObject private var macModel = AppleModelControl.shared
    let choice: ModelChoice
    let automatic: (title: String, detail: String)
    var follows = ModelDefaults.Work.commands
    let offersMac: Bool
    var plans = AgentPlan.clis
    var work: ModelDefaults.Work?
    var trouble: String?
    let pick: (ModelChoice) -> Void
    /// Esc in the search: the list put away.
    var close: () -> Void = {}
    @State private var query = ""
    @State private var hovered: AgentModel?
    /// The row the keys are on, among `rows`; the pointer moves it too, so
    /// one row is lit at a time.
    @State private var spot = 0
    /// Set by the keys, so the list scrolls to them; never by the pointer.
    @State private var scrollTo: String?

    private struct Group: Identifiable {
        let id: String
        let title: String
        let cli: String
        /// Every one it has was left out in Models in lists.
        var allHidden = false
        let models: [AgentModel]
    }

    /// Whether a plan's models can be picked here: on this Mac, connected
    /// in Yab, and able to do this list's work.
    private func pickable(_ cli: String) -> Bool {
        cli == "mac" ? macModel.enabled : (AgentModels.here(cli) && AgentSetup.connected(cli) && work?.refusal(cli) == nil)
    }

    /// Every model the list can show, before the search.
    private var every: [Group] {
        // What Models in lists left out stays out, unless it is the one chosen.
        let hidden = ModelDefaults.shared.hidden
        func shown(_ models: [AgentModel]) -> [AgentModel] {
            models.filter { !hidden.contains($0.id) || isChosen($0) }
        }
        var all: [Group] = []
        if offersMac && macModel.enabled { all.append(Group(id: "mac", title: "On this Mac", cli: "mac", models: [AgentModels.mac])) }
        for plan in AgentPlan.all where plans.contains(plan.cli) && (plan.listedAway || AgentModels.here(plan.cli)) {
            let models = plan.models, kept = shown(models)
            all.append(Group(id: plan.cli, title: plan.name + " plan", cli: plan.cli,
                             allHidden: kept.isEmpty && !models.isEmpty, models: kept))
        }
        return all
    }

    private var groups: [Group] {
        let all = every
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return all }
        return all.map { group in
            Group(id: group.id, title: group.title, cli: group.cli, allHidden: group.allHidden, models: group.models.filter { model in
                // The tools' names find them too: "codex", "claude code".
                let text = (model.name + " " + group.title + " " + AgentModels.agentName(model.cli)
                            + (model.cli == "mac" ? "" : " " + AgentSetupModel.tool(model.cli))).lowercased()
                return words.allSatisfy { text.contains($0) }
            })
        }.filter { !$0.models.isEmpty }
    }

    /// What the keys walk, in the order shown: Auto with no search, then
    /// every model of a plan that is here.
    private var rows: [(id: String, choice: ModelChoice, model: AgentModel?)] {
        var out: [(id: String, choice: ModelChoice, model: AgentModel?)] = []
        if query.isEmpty { out.append((id: "auto", choice: ModelChoice(), model: nil)) }
        for group in groups where pickable(group.cli) {
            out += group.models.map { model in
                (id: model.id, choice: ModelChoice(cli: model.cli, model: model.model.isEmpty ? nil : model.model), model: model)
            }
        }
        return out
    }

    private func note(_ words: String) -> some View {
        Text(words)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
    }

    /// The one in use; a plan with no model of its own runs its default,
    /// the first its agent lists.
    private func isChosen(_ model: AgentModel) -> Bool {
        ModelField.isChosen(model, choice: choice)
    }

    private func move(_ by: Int) {
        let all = rows
        guard !all.isEmpty else { return }
        spot = max(0, min(all.count - 1, spot + by))
        hovered = all[spot].model
        scrollTo = all[spot].id
    }

    private func take() {
        let all = rows
        if all.indices.contains(spot) { pick(all[spot].choice) }
    }

    private func light(_ id: String) {
        if let at = rows.firstIndex(where: { $0.id == id }) { spot = at }
    }

    var body: some View {
        let lit = rows.indices.contains(spot) ? rows[spot].id : nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Symbol("magnifyingglass", size: 12)
                    .foregroundStyle(.secondary)
                // Takes the keyboard as the list opens: typing filters at
                // once, ↑↓ walk the rows, ↩ takes one, Esc puts it away.
                PickerSearch(text: $query, placeholder: "Search models", move: move, side: { _ in },
                             pick: take, close: close, size: 13)
                    .frame(height: 18)
            }
            .padding(12)
            Divider()
            ScrollViewReader { reader in
            ThreadScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty {
                        ModelRow(cli: nil, name: automatic.title, source: automatic.detail, chosen: choice.cli == nil, lit: lit == "auto") {
                            pick(ModelChoice())
                        }
                        .id("auto")
                        .onHover { if $0 { light("auto"); hovered = nil } }
                    } else if groups.isEmpty {
                        Text("No model called “\(query.trimmingCharacters(in: .whitespaces))”")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    ForEach(groups) { group in
                        // The plan and how much of it is used, as the
                        // picker in the middle of the window heads it.
                        ModelPlanHead(title: group.title, cli: group.cli, size: 11)
                        if let refusal = work?.refusal(group.cli) {
                            // Shown, greyed, with why: it is your plan,
                            // just not one this work runs on.
                            note(refusal)
                            ForEach(group.models) { model in
                                ModelRow(cli: model.cli, name: model.name, source: AgentModels.agentName(model.cli),
                                         chosen: false) {}
                                    .disabled(true)
                                    .opacity(0.45)
                            }
                        } else if !AgentModels.here(group.cli) || !AgentSetup.connected(group.cli) {
                            note("Connect \(AgentModels.agentName(group.cli)) in Settings › AI › Models to use these.")
                        } else if group.models.isEmpty {
                            note(ModelField.emptyWords(group.cli, allHidden: group.allHidden))
                        } else {
                            ForEach(group.models) { model in
                                ModelRow(cli: model.cli, name: model.name,
                                         source: model.cli == "mac" ? "This Mac" : AgentModels.agentName(model.cli),
                                         chosen: isChosen(model), lit: lit == model.id) {
                                    pick(ModelChoice(cli: model.cli, model: model.model.isEmpty ? nil : model.model))
                                }
                                .id(model.id)
                                .onHover { inside in
                                    if inside { hovered = model; light(model.id) } else if hovered == model { hovered = nil }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 360)
            .onChange(of: scrollTo) { _, id in if let id { reader.scrollTo(id) } }
            }
            Divider()
            about
                .padding(12)
        }
        .frame(width: 360)
        // Usage is read without a model request, as the picker reads it.
        .task {
            guard let found = Shell.cached else { return }
            await PlanAccounts.shared.ask(plans, found: found, refreshBlocked: true)
        }
        .onAppear {
            // Up on the one in use, as a menu opens on its answer.
            let all = rows
            spot = all.firstIndex { row in row.model.map(isChosen) ?? (choice.cli == nil) } ?? 0
        }
        .onChange(of: query) { _, _ in spot = 0 }
    }

    /// What the model under the pointer is, else the chosen one, at the
    /// height of the longest it can say, so the list's foot stands still
    /// as the pointer runs down it.
    private var about: some View {
        let shown = hovered ?? AgentModels.find(choice.cli, choice.model)
        return ZStack(alignment: .topLeading) {
            facts(nil).hidden()
            ForEach(every.flatMap(\.models)) { model in
                facts(model).hidden()
            }
            facts(shown)
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
    }

    private func facts(_ model: AgentModel?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let model {
                Text(model.name).font(.system(size: 12.5, weight: .semibold))
                if !model.about.isEmpty {
                    Text(model.about).foregroundStyle(.secondary)
                }
                Text(model.cli == "mac" ? "Nothing leaves this Mac."
                     : "Runs on your \(AgentModels.agentName(model.cli)) plan.")
                    .foregroundStyle(.secondary)
            } else if let trouble {
                Text(automatic.title).font(.system(size: 12.5, weight: .semibold))
                Text(trouble).foregroundStyle(.secondary)
            } else {
                Text(automatic.title).font(.system(size: 12.5, weight: .semibold))
                Text(automatic.title == "Default" ? "Follows the \(follows.title) default in Settings › AI › Models."
                     : work == .tasks && ModelDefaults.shared.automatic(.tasks) == ModelDefaults.shared.pick(.chats).cli
                        ? "Runs on \(automatic.detail), the plan Chats uses, on its default model."
                     : work == .drafts ? "Runs on \(automatic.detail)."
                     : "Runs on \(automatic.detail), on its default model.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// One model in the list: its agent's mark, its name, who runs it.
private struct ModelRow: View {
    let cli: String?
    let name: String
    let source: String
    let chosen: Bool
    /// Where the keys are, or the pointer last was.
    var lit = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ModelMark(cli: cli)
                Text(name)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(source)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Symbol("checkmark", size: 10, weight: .semibold)
                    .opacity(chosen ? 1 : 0)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.primary.opacity(lit ? 0.07 : 0),
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }
}

/// Settings › AI › Models: the default model for each kind of work.
struct DefaultModels: View {
    @ObservedObject private var defaults = ModelDefaults.shared
    @ObservedObject private var keys = APIKeys.shared
    @State private var reader = FieldReader.chosen

    /// Who reads now: Jev chosen without a key on is this Mac's model.
    private var reading: FieldReader { reader == .jev && !(keys.anyOpenRouter && keys.on) ? .system : reader }

    var body: some View {
        Section {
            ForEach(ModelDefaults.Work.allCases, id: \.self) { work in
                let writer = ModelDefaults.draftWriter(chosen: defaults[.drafts].cli, connected: PlanText.agents)
                let trouble = ModelDefaults.autoTrouble(work, writer: writer)
                let said = trouble ?? (work == .tasks ? defaults.tasksNote : nil)
                SettingsRow(work.title, detail: work.detail + (said.map { " " + $0 } ?? "")) {
                    VStack(alignment: .trailing, spacing: 6) {
                        ModelField(choice: defaults.binding(work),
                                   automatic: ("Auto", ModelDefaults.autoDetail(work, writer: writer, preferred: defaults.automatic(work))),
                                   plans: work.plans, work: work, trouble: trouble)
                        EffortField(choice: defaults.binding(work))
                    }
                }
                .settingsAnchor("agents-model-" + work.rawValue)
            }
            SettingsRow("Reading the Field", detail: reading.detail + " Detects requests in ⌘T (Experimental › Actions in the Field).") {
                // Jev wears the key mark it runs on; without a key, picking
                // it asks for one first.
                DropMenu("Reading the Field",
                         options: [DropOption(title: FieldReader.system.title, value: FieldReader.system),
                                   DropOption(title: keys.anyOpenRouter ? FieldReader.jev.title : "TypeSafe Jev · Add Key…",
                                              value: FieldReader.jev, picture: Glyphs.image("key", size: 12))],
                         selection: Binding(get: { reading }, set: { value in
                    if value == .jev, !(keys.anyOpenRouter && keys.on) {
                        if !keys.anyOpenRouter { keys.open(.openrouter) } else { keys.on = true; reader = .jev; FieldReader.chosen = .jev }
                    } else {
                        reader = value
                        FieldReader.chosen = value
                    }
                }))
                .fixedSize()
                .onReceive(keys.$openRouter) { _ in reader = FieldReader.chosen }
            }
            .settingsAnchor("agents-model-field")
            SettingsNote("Each model uses the listed subscription. Override individual commands in Commands.")
        } header: {
            Text("Default models").foregroundStyle(.secondary)
        }
    }
}

/// Settings › AI › Models, Raycast's Models & Providers: the plans (Claude
/// Code's and Codex's sign-ins, and this Mac's own model), the default
/// model for each kind of work, and which models the lists offer.
struct ModelsPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var setup = AgentSetupModel.shared
    @ObservedObject private var accounts = PlanAccounts.shared
    @ObservedObject private var keys = APIKeys.shared
    @ObservedObject private var gemini = GeminiAccount.shared
    @ObservedObject private var geminiChoices = GeminiChoices.shared

    var body: some View {
        PageHero(page: .models)
        Section {
            AppleModelRow()
            ForEach(setup.order.filter { $0 != "gemini" && setup.connected($0) }, id: \.self) { cli in
                ForEach(accounts.all(cli)) { account in
                    PlanAccountRow(account: account, browser: browser)
                        .settingsAnchor(account.usual ? "agents-" + cli : "models-account-" + account.id)
                }
            }
            // OpenRouter's keys, for Jev, after the agents' plans and keys.
            ForEach(keys.openRouter, id: \.self) { id in
                OpenRouterKeyRow(id: id, browser: browser)
            }
            if setup.showsGemini {
                GeminiPlanRow(browser: browser)
                    .settingsAnchor("models-gemini")
            }
            AddAccountRow(browser: browser)
                .settingsAnchor("models-add")
        } header: {
            Text("Plans").foregroundStyle(.secondary)
        }
        .task { await look() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await look() }
        }
        // Every connected plan shares the same defaults.
        if setup.anyConnected || gemini.ready || browser.prefs.fieldRequests {
            DefaultModels()
            ModelsInLists()
        }
    }

    /// Who each plan is, from the agents' own files. How much room each
    /// has is what the plans last said when a task ran: a page on screen
    /// never runs an agent to ask.
    private func look() async {
        await setup.look()
        await GeminiAccount.shared.look()
        await gemini.identify()
        await geminiChoices.look(browser, switching: setup.connected("gemini") && gemini.ready, refreshIdentity: false)
        guard let found = setup.found else { return }
        await accounts.look(found)
    }
}

/// This Mac's plan has a Yab-only opt-out, beside its hardware status.
struct AppleModelRow: View {
    @ObservedObject var model = AppleModelControl.shared

    var body: some View {
        HStack(spacing: 12) {
            Symbol("laptopcomputer", size: 16)
                .frame(width: PlanAccountRow.markSide, height: PlanAccountRow.markSide)
            VStack(alignment: .leading, spacing: 3) { // design: preserve the existing SettingsRow text gap
                Text("Apple Intelligence")
                Text(!model.enabled ? "Apple Intelligence is off in Yab."
                     : FormModel.ready ? "Process short text on this Mac with Apple Intelligence."
                     : "Apple Intelligence is off. Short text uses your connected subscription.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(FormModel.ready ? "Ready" : "Off").foregroundStyle(.secondary)
            SettingsMoreMenu("More options for Apple Intelligence", entries: model.menuEntries) {
                PlanAccountRow.moreFace
            }
        }
        .settingsAnchor("models-mac")
        .settingsContextMenu(model.menuEntries)
    }
}

/// Gemini's plan: Google's Antigravity CLI signed in to your Google
/// account in Yab's existing profile. Sign In and Switch Account use the
/// shared chooser and a Yab tab; only installation uses Terminal.
private struct GeminiPlanRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var gemini = GeminiAccount.shared
    @ObservedObject private var accounts = PlanAccounts.shared

    var body: some View {
        HStack(spacing: 12) {
            // The account is in words under the name, as on the other plans.
            AgentMark(cli: "gemini", side: PlanAccountRow.markSide)
            VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own gap
                Text("Gemini")
                if let who {
                    Text(who)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if gemini.waiting != nil {
                ProgressView().controlSize(.small)
                if gemini.waiting == .signingIn {
                    Button("Show") { gemini.showSignIn() }.settingsButton(.quiet)
                }
                Button("Cancel") { gemini.cancel() }
                    .settingsButton(.quiet)
            } else if gemini.binary == nil {
                Button("Set Up") { gemini.install() }
                    .settingsButton()
            } else if !gemini.ready {
                Button("Sign In") { AgentSetupModel.shared.chooseGemini(browser) }
                    .settingsButton()
            } else if gemini.ready {
                QuotaRing(account: PlanAccount(id: "gemini", cli: "gemini", email: gemini.identity?.email, plan: gemini.identity?.plan))
            }
            SettingsMoreMenu("More options for Gemini", entries: menu) {
                PlanAccountRow.moreFace
            }
        }
    }

    private func menu() -> [SettingsMenuEntry] {
        var entries: [SettingsMenuEntry] = [.item("Check Again") { Task { await gemini.look(fresh: true); await gemini.identify() } }]
        if gemini.binary != nil {
            entries.append(.item(gemini.ready ? "Switch Account" : "Sign In") {
                AgentSetupModel.shared.chooseGemini(browser)
            })
        }
        entries.append(.destructive("Remove Gemini") { AgentSetupModel.shared.disconnect(["gemini"], browser) })
        return entries
    }

    private var detail: String {
        if let trouble = gemini.trouble { return trouble }
        switch gemini.waiting {
        case .installing: return "Paste the command in Terminal to install Antigravity CLI."
        case .signingIn:
            if !gemini.pageOpen { return "Opening Google's sign-in…" }
            if let choice = gemini.choice, let email = choice.email {
                return "Allow Gemini in the " + (choice.place ?? "Yab") + " tab as " + email
            }
            return "Allow Gemini in the private Google sign-in tab."
        case nil: break
        }
        if gemini.binary == nil { return "Google's Antigravity CLI, with your Google AI plan." }
        return gemini.notice ?? ""
    }

    /// Who it is signed in as, on what plan, and whether it has room, the
    /// way PlanAccountRow says it; nil while a sentence says more.
    private var who: String? {
        guard gemini.trouble == nil, gemini.waiting == nil, gemini.binary != nil else { return nil }
        if gemini.signedIn != true { return [gemini.identity?.email, "Signed out"].compactMap { $0 }.joined(separator: " · ") }
        guard gemini.notice == nil else { return nil }
        var parts = [gemini.identity?.email ?? "Signed in on this Mac", gemini.identity?.plan.map { PlanAccounts.tier("gemini", $0) }].compactMap { $0 }
        if let until = accounts.quotas["gemini"]?.out, accounts.out("gemini") {
            parts.append("Out until " + PlanAccounts.when(until))
        }
        return parts.joined(separator: " · ")
    }
}


/// One plan account: whose plan it is in
/// its mark and name, who it is signed in as, how much room it has left in
/// words, and the rest behind ···. Tasks try them top to bottom.
private struct PlanAccountRow: View {
    static let markSide: CGFloat = 24
    let account: PlanAccount
    @ObservedObject var browser: Browser
    @ObservedObject private var accounts = PlanAccounts.shared
    @ObservedObject private var setup = AgentSetupModel.shared

    var body: some View {
        HStack(spacing: 12) {
            AgentMark(cli: account.cli, side: Self.markSide)
            VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own gap
                Text(AgentSetupModel.plan(account.cli))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if setup.working == account.cli {
                ProgressView().controlSize(.small)
            } else if let renewal {
                HStack(spacing: 8) {
                    if renewal.wheel { ProgressView().controlSize(.small) }
                    if renewal.cancel {
                        Button("Cancel") { setup.cancel() }
                            .settingsButton(.quiet)
                    }
                    if let show = renewal.show {
                        Button(show) { setup.showSignIn() }
                            .settingsButton()
                    }
                }
            } else if account.keyed {
                // A key has no plan's windows to fill.
            } else if signedOut {
                Button("Sign In") { setup.connect([account.cli], browser, account: account.id) }
                    .settingsButton()
                    .disabled(setup.busy)
            } else {
                QuotaRing(account: account)
            }
            more
        }
    }

    private var signedOut: Bool {
        accounts.signedOut.contains(account.id) || (account.usual && setup.signedIn[account.cli] == false)
    }

    /// Connected with an API key of yours (AgentKey), not a plan.
    private var keyed: Bool { account.usual && setup.signedIn[account.cli] == true && AgentKey.keyed(account.cli) }

    /// Its agent signing in again from here, step by step.
    private var renewal: Renewal? {
        guard setup.renewing == account.id else { return nil }
        return Renewal.of(setup.flow, page: setup.page)
    }

    /// Who it is and on what plan; which one tasks start on, once there
    /// is more than one to start on. While it signs in again, the step;
    /// after a try that stopped, why.
    private var detail: String {
        if account.keyed { return keyDetail }
        if let renewal { return renewal.detail }
        if signedOut, let trouble = setup.trouble, trouble.clis.contains(account.cli) { return trouble.words }
        if signedOut { return account.email.map { $0 + " · Signed out" } ?? "Signed out" }
        if account.usual, !browser.prefs.bench { return "Paused in AI › Agents" }
        let plan = account.plan.map { PlanAccounts.tier(account.cli, $0) }
        // Your `claude setup-token` token comes before any sign-in: whose it
        // is, Claude Code doesn't say, so not an email it might not be.
        let token = account.usual && account.cli == "claude" && (setup.found?.env[Shell.claudeToken]).map { !$0.isEmpty } == true
        // A key of yours comes before both, and is billed per use.
        let who = keyed ? "API key, billed per use by \(AgentKey.provider(account.cli))"
            : token ? "Signed in with a setup token" : account.email ?? (account.usual ? "Signed in on this Mac" : "Another account")
        var parts = [who, plan].compactMap { $0 }
        if let until = accounts.quotas[account.id]?.out, accounts.out(account.id) {
            parts.append("Out until " + PlanAccounts.when(until))
        } else if accounts.all(account.cli).count > 1, accounts.pick(account.cli)?.id == account.id {
            parts.append("In use")
        }
        return parts.joined(separator: " · ")
    }

    /// An API key of yours: its last four letters, who bills it, and
    /// whether tasks run on it now or it sits out.
    private var keyDetail: String {
        var parts = ["API key " + (account.tail ?? ""), "billed per use by " + AgentKey.provider(account.cli)]
        if let until = accounts.quotas[account.id]?.out, accounts.out(account.id) {
            parts.append("Turned away, back " + PlanAccounts.when(until))
        } else if accounts.all(account.cli).count > 1, accounts.pick(account.cli)?.id == account.id {
            parts.append("In use")
        }
        return parts.joined(separator: " · ")
    }

    /// The ··· at the end of an account's or a key's row.
    static var moreFace: some View {
        Symbol("ellipsis", size: 14)
            .foregroundStyle(.secondary)
            .frame(width: markSide, height: markSide)
            .contentShape(Rectangle())
    }

    private var keyMenu: some View {
        SettingsMoreMenu("More options for \(AgentKey.provider(account.cli)) key \(account.tail ?? "")", entries: keyEntries) {
            Self.moreFace
        }
    }

    private func keyEntries() -> [SettingsMenuEntry] {
        var entries: [SettingsMenuEntry] = [
            .item("Manage in \(AgentKey.console(account.cli))") {
                browser.tuning = false
                browser.open(AgentKey.keysPage(account.cli), foreground: true)
            },
            .item("Replace Key…") { APIKeys.shared.open(.of(account.cli), replacing: account.id) },
        ]
        let ids = accounts.all(account.cli).map(\.id)
        if ids.first != account.id {
            entries.append(.item("Move Up") { accounts.move(account.id, by: -1) })
        }
        if ids.last != account.id {
            entries.append(.item("Move Down") { accounts.move(account.id, by: 1) })
        }
        entries.append(.destructive("Remove Key") { accounts.remove(account.id) })
        return entries
    }

    @ViewBuilder private var more: some View {
        if account.keyed { keyMenu } else { planMenu }
    }

    private var planMenu: some View {
        SettingsMoreMenu("More options for \(account.email ?? AgentSetupModel.plan(account.cli))", entries: planEntries) {
            Self.moreFace
        }
    }

    private func planEntries() -> [SettingsMenuEntry] {
        var entries: [SettingsMenuEntry] = []
        if accounts.all(account.cli).first?.id != account.id {
            entries.append(.item("Try First") { accounts.moveFirst(account.id, account.cli) })
        }
        if signedOut {
            entries.append(.item("Sign In", enabled: !setup.busy) { setup.connect([account.cli], browser, account: account.id) })
        }
        if account.cli != "cursor" {
            entries.append(.item("Add Another \(AgentSetupModel.plan(account.cli)) Account", enabled: accounts.adding == nil) {
                accounts.add(account.cli, browser)
            })
        }
        if keyed {
            entries.append(.destructive("Remove Key") { setup.removeKey(account.cli) })
        }
        if account.usual {
            entries.append(.destructive("Disconnect \(AgentSetupModel.name(account.cli))") { setup.disconnect([account.cli], browser) })
        } else {
            entries.append(.destructive("Remove Account") { accounts.remove(account.id) })
        }
        return entries
    }
}

/// A plan row while its agent signs in again (`AgentSetupModel.renewing`):
/// the step in the row's words, and on its right a wheel, or the sign-in
/// to bring back and Cancel. Nothing is said when it is done: the row goes
/// back to its plan.
struct Renewal: Equatable {
    let detail: String
    var wheel = false
    /// Show (its Yab tab) or Open Again (the other browser's page).
    var show: String?
    var cancel = false

    static func of(_ flow: AgentSetupModel.Flow?, page: Agents.SignInPage?) -> Renewal? {
        switch flow {
        case .preparing: return Renewal(detail: "Checking the sign-in…", wheel: true)
        case .signingIn(let cli):
            let plan = AgentSetupModel.plan(cli)
            switch page {
            case .yab: return Renewal(detail: "Sign in to \(plan) in the Yab tab", show: "Show", cancel: true)
            case .browser(let name): return Renewal(detail: "Sign in to \(plan) in \(name ?? "your browser")", show: "Open Again", cancel: true)
            case .opening, nil: return Renewal(detail: "Opening the sign-in…", wheel: true, cancel: true)
            }
        case .finishing: return Renewal(detail: "Signed in. Reconnecting…", wheel: true)
        default: return nil
        }
    }
}

/// How full the account's plan is: a ring, the fullest
/// window's share drawn round it, and each window in words in a popover on
/// a click. An empty ring until the plan has said.
private struct QuotaRing: View {
    let account: PlanAccount
    @ObservedObject private var accounts = PlanAccounts.shared
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let used = accounts.fullest(account.id)
        Button { open.toggle() } label: {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.14), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0, min(1, used ?? 0)))
                    .stroke(tint(used), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
            .frame(width: PlanAccountRow.markSide, height: PlanAccountRow.markSide)
            .background(Color.primary.opacity(hovering || open ? 0.07 : 0),
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(accounts.words(account.id) ?? "Usage")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            QuotaDetails(account: account)
        }
    }

    /// Ink as it fills, orange near the end and once it is out.
    private func tint(_ used: Double?) -> Color {
        guard let used else { return .clear }
        return used >= 0.9 || accounts.out(account.id) ? .orange : .primary
    }
}

/// The ring's popover: each window the plan counts, how full, and when it
/// starts over.
struct QuotaDetails: View {
    let account: PlanAccount
    @ObservedObject private var accounts = PlanAccounts.shared

    var body: some View {
        let windows = accounts.windows(account.id)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentSetupModel.plan(account.cli) + (account.plan.map { " " + PlanAccounts.tier(account.cli, $0) } ?? ""))
                    .font(.system(size: 12, weight: .semibold))
                if let email = account.email {
                    Text(email).foregroundStyle(.secondary)
                }
            }
            if windows.isEmpty {
                Text(account.cli == "cursor" ? "Cursor doesn't share how much is left." : "Yab hasn't run anything on this account yet, so its plan hasn't said how much is left.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if account.cli == "cursor" {
                    Link("See Usage on cursor.com", destination: CursorRunner.usage)
                        .buttonStyle(.yab(.quiet, .small))
                }
            }
            ForEach(windows, id: \.name) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(PlanAccounts.named(item.name).title)
                        Spacer()
                        Text("\(Int((item.window.used * 100).rounded()))% used").foregroundStyle(.secondary)
                    }
                    ProgressView(value: max(0, min(1, item.window.used)))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(item.window.used >= 0.9 ? .orange : .primary)
                    if let resets = item.window.resets {
                        Text("Resets " + PlanAccounts.when(resets))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let seen = accounts.quotas[account.id]?.seen, !windows.isEmpty {
                Text("As of " + AgentSetupModel.ago(seen))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(width: 200)
    }
}

/// + Add Account: the plans there are, each connected,
/// installed or signed in to again as it needs. Another account's sign-in
/// opens in a private tab.
private struct AddAccountRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var accounts = PlanAccounts.shared
    @ObservedObject private var setup = AgentSetupModel.shared
    @State private var hovering = false
    @State private var shown = false
    @State private var place = DropAnchor.Place()

    var body: some View {
        if let cli = accounts.adding {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                    .frame(width: PlanAccountRow.markSide)
                Text(PlanAccounts.stepWords(cli, accounts.step))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Once the CLI is done there is nothing left to stop.
                if accounts.step != .checking {
                    Button("Cancel") { accounts.cancelAdding() }
                        .settingsButton(.quiet)
                }
                if accounts.step == .yab {
                    Button("Show") { accounts.showSignIn(cli) }
                        .settingsButton()
                }
            }
        } else {
            // The plans in Settings' own list (DropPopup), each with its
            // mark, as every other menu here opens.
            HStack(spacing: 12) {
                Symbol("plus", size: 14)
                    .frame(width: PlanAccountRow.markSide)
                VStack(alignment: .leading, spacing: 3) { // design: SettingsRow's own gap
                    Text("Add Account")
                    // The last add that stopped, until the next.
                    if let trouble = accounts.trouble {
                        TroubleLine(words: trouble)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering || shown ? Palette.ink : Palette.muted)
            .contentShape(Rectangle())
            .overlay(DropAnchor(place: place, title: "Add Account", press: open, hover: { hovering = $0 }))
            .opacity(setup.busy ? 0.5 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
        }
    }

    /// The plans, then under a line your own keys for each, with a search
    /// on top as the search engine's list has.
    private func open() {
        guard !setup.busy, let view = place.view, view.window != nil else { return }
        let clis = AgentSetupModel.clis
        let providers = APIKeys.Provider.allCases
        let lines = clis.map { cli in
            let signed = cli == "gemini" ? GeminiChoices.shared.rows.filter { $0.source != .another }.count : 0
            return DropList.Line(title: AgentSetupModel.plan(cli),
                          picture: Glyphs.image(FieldAnswer.mark(cli), side: 16),
                          note: !setup.installed(cli) ? "Set up first" : signed > 0 ? "\(signed) signed in" : nil)
        } + providers.map { provider in
            DropList.Line(title: provider.name + " API Key", picture: Glyphs.image("key", side: 16), note: "for " + provider.runs)
        }
        let list = DropList(options: lines, chosen: 0, divideBefore: clis.count, inset: DropFace.inset, alwaysSearch: true)
        shown = true
        DropPopup.show(list, under: view, width: 260) { index in
            shown = false
            guard let index else { return }
            if clis.indices.contains(index) { pick(clis[index]) }
            else if providers.indices.contains(index - clis.count) { APIKeys.shared.open(providers[index - clis.count]) }
        }
    }

    private func pick(_ cli: String) {
        setup.addAccount(cli, browser)
    }
}

/// Raycast's Manage Models: every model a plan has, and whether the lists
/// offer it. One left out still runs where it was already chosen.
private struct ModelsInLists: View {
    @ObservedObject private var defaults = ModelDefaults.shared
    /// Plans whose whole list is open.
    @State private var open: Set<String> = []
    @State private var collapsed: Set<String> = []

    /// How many of a plan's models show before Show All: Cursor's account
    /// lists dozens.
    static let first = 6

    /// Each plan's models in order, a long list cut at `first` until opened.
    /// Cursor's only while its plan is connected here.
    private var plans: [Shown] {
        AgentPlan.all.filter { $0.listedAway || AgentModels.here($0.cli) }.map { plan in
            let models = plan.models
            let cut = models.count > Self.first + 2 && !open.contains(plan.cli)
            return Shown(plan: plan, models: cut ? Array(models.prefix(Self.first)) : models, more: cut ? models.count - Self.first : 0)
        }
    }

    private struct Shown: Identifiable {
        let plan: AgentPlan
        let models: [AgentModel]
        let more: Int
        var id: String { plan.cli }
    }

    var body: some View {
        ForEach(plans) { shown in
            Section {
                Button {
                    if !collapsed.insert(shown.id).inserted { collapsed.remove(shown.id) }
                } label: {
                    // The plan's line carries the column titles: no row of its own.
                    HStack(spacing: 16) {
                        HStack(spacing: 8) {
                            AgentMark(cli: shown.id, side: 16)
                            Text(shown.plan.name).fontWeight(.medium)
                            Symbol(collapsed.contains(shown.id) ? "chevron.right" : "chevron.down", size: 9)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !collapsed.contains(shown.id) {
                            Group {
                                Text("Context").frame(width: 64, alignment: .trailing)
                                Text("Show").frame(width: 36)
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(shown.plan.name) models")
                .accessibilityValue(collapsed.contains(shown.id) ? "Collapsed" : "Expanded")
                if !collapsed.contains(shown.id) {
                    ForEach(shown.models) { model in row(model) }
                    if shown.more > 0 {
                        SettingsRow("\(shown.more) more \(shown.plan.name) models") {
                            Button("Show All") { open.insert(shown.id) }
                                .settingsButton(.quiet)
                        }
                    }
                }
            } header: {
                if shown.id == plans.first?.id {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Models in lists")
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        SettingsNote("Which models the pickers offer. One turned off still runs where it is chosen.")
                    }
                }
            } footer: {
                if shown.id == plans.last?.id {
                    SettingsNote("Available GPT and Cursor models depend on your connected subscriptions.")
                }
            }
            .settingsAnchor(shown.id == plans.first?.id ? "models-lists" : "models-lists-" + shown.id)
        }
    }

    private func row(_ model: AgentModel) -> some View {
        let opacity = defaults.hidden.contains(model.id) ? 0.45 : 1.0
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !model.about.isEmpty {
                    // A description that fits needs no tip over the next model.
                    ViewThatFits(in: .horizontal) {
                        Text(model.about)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(model.about)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .pointerTip(model.about)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(opacity)
            Text(model.context.map { $0 >= 1_000_000 ? "\($0 / 1_000_000)M" : "\($0 / 1000)k" } ?? "—")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
                .opacity(opacity)
            Toggle(model.name, isOn: Binding(
                get: { !defaults.hidden.contains(model.id) },
                set: { on in
                    if on { defaults.hidden.remove(model.id) } else { defaults.hidden.insert(model.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .frame(width: 36)
        }
        .frame(minHeight: 36)
    }
}

extension ModelField {
    /// What a field says for a choice: the model's name, or for a plan
    /// with no model of its own, its default's ("Gemini 3 Pro"), else the
    /// plan's name; nil for Auto.
    static func title(_ choice: ModelChoice) -> String? {
        if let model = AgentModels.find(choice.cli, choice.model) { return model.name }
        guard let plan = AgentPlan.of(choice.cli) else { return nil }
        return choice.model == nil ? plan.models.first?.name ?? plan.name : plan.name
    }

    /// A provider-only choice uses its first model even when that model
    /// was hidden from the list.
    static func isChosen(_ model: AgentModel, choice: ModelChoice) -> Bool {
        guard choice.cli == model.cli else { return false }
        if model.cli == "mac" { return true }
        if let chosen = AgentModels.find(choice.cli, choice.model) { return chosen.id == model.id }
        guard choice.model == nil else { return false }
        return AgentPlan.of(model.cli)?.models.first?.id == model.id
    }

    /// What a plan's part of the list says with no model to show.
    static func emptyWords(_ cli: String, allHidden: Bool) -> String {
        let name = AgentSetupModel.name(cli)
        if allHidden { return "\(name)'s models are all off in Models in lists." }
        return cli == "codex" ? "ChatGPT's models show here after its first task."
            : "\(name)'s models show here once \(AgentSetupModel.tool(cli)) lists them."
    }

    /// The list as it opens, drawn in a window of its own off screen, for a
    /// picture of it (bench `modellist`): a popover shows only in front.
    /// `work`: that default's list, as Settings › AI › Models opens it.
    static func listPicture(choice: ModelChoice, offersMac: Bool, work: ModelDefaults.Work? = nil, plans: [String]? = nil,
                            to path: String) -> Bool {
        let writer = ModelDefaults.draftWriter(chosen: ModelDefaults.shared[.drafts].cli, connected: PlanText.agents)
        let list = ModelList(choice: choice,
                             automatic: offersMac ? ("Default", ModelDefaults.shared.name(.commands))
                                 : ("Auto", work.map { ModelDefaults.autoDetail($0, writer: writer, preferred: ModelDefaults.shared.automatic($0)) }
                                     ?? AgentModels.agentName(Agents.preferred)),
                             offersMac: offersMac, plans: plans ?? work?.plans ?? ["claude", "codex", "cursor"], work: work,
                             trouble: work.flatMap { ModelDefaults.autoTrouble($0, writer: writer) }, pick: { _ in })
            .background(Color(nsColor: .windowBackgroundColor))
        let view = NSHostingView(rootView: list)
        view.frame.size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: 0), size: view.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WindowHosting.measured(view)
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
