import AppKit
import SwiftUI

// Picking a model: a list in the middle of the
// window, its search on top, the models you used last, then each plan
// under a head that says how much of it is used; beside it, what the model
// under the pointer is. The one in use comes up chosen, ↩ takes it, ← →
// change its effort. For the ⌘J answer (answer again on) and the chat
// column's head (the model for what is asked next).

/// What a picker is asked for: its title, the plans it offers, what is in
/// use, and what to do with the pick.
struct ModelPickerRequest: Identifiable {
    let id = UUID()
    var title: String
    var clis: [String]
    var offersMac = false
    var choice: ModelChoice
    /// Words already in its search as it opens.
    var query = ""
    var pick: (ModelChoice) -> Void
}

/// The effort the picker offers as you move through its list: one effort
/// that follows you from model to model, by keys or by pointer, as the
/// Settings field keeps it when its model changes (ModelField). A model
/// that doesn't take it says Auto, and ↩ takes Auto there, so the row
/// always says what a pick would get.
struct PickerEffort: Equatable {
    /// Picked with ← →, or the one in use as the picker opened; nil is Auto.
    var picked: String?

    /// What the row under the pointer says, and what ↩ takes on it.
    func on(_ model: AgentModel) -> String? {
        guard let picked, model.efforts.contains(picked) else { return nil }
        return picked
    }

    /// ← → : the next effort the model takes, from the one it says now,
    /// Auto first.
    mutating func turn(_ model: AgentModel, by: Int) {
        guard !model.efforts.isEmpty else { return }
        let steps: [String?] = [nil] + model.efforts.map(Optional.some)
        let at = steps.firstIndex(of: on(model)) ?? 0
        picked = steps[max(0, min(steps.count - 1, at + by))]
    }
}

struct ModelPickerLayer: View {
    let browser: Browser
    let request: ModelPickerRequest

    var body: some View {
        GeometryReader { space in
            ZStack {
                // A click beside it puts it away.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { browser.modelPicker = nil }
                ModelPicker(browser: browser, request: request, room: space.size.width)
                    .id(request.id)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

private struct ModelPicker: View {
    let browser: Browser
    let request: ModelPickerRequest
    /// The window's width: what the list and its details card must fit in.
    let room: CGFloat
    @ObservedObject private var accounts = PlanAccounts.shared
    @State private var query = ""
    @State private var spot = 0
    @State private var effort = PickerEffort()
    @State private var info = ModelPicker.infoShown
    /// Where the list scrolls to: the row the keys moved to, or the one in
    /// use as it opens; never the one under the pointer.
    @State private var scrollTo: String?

    static let width: CGFloat = 480
    static let side: CGFloat = 260
    static let height: CGFloat = 440
    /// The details card's distance from the list, and both from the window's edge.
    static let gap: CGFloat = 10
    static let margin: CGFloat = 12

    /// Whether the details card fits in the window beside the list.
    private var cardFits: Bool { Self.width + Self.gap + Self.side + 2 * Self.margin <= room }

    /// How far the list moves left so the card beside it stays in the
    /// window: none while the middle leaves it room.
    private var shift: CGFloat {
        guard info, current != nil, cardFits else { return 0 }
        let cardEdge = room / 2 + Self.width / 2 + Self.gap + Self.side
        return max(0, cardEdge - (room - Self.margin))
    }

    private enum Line: Identifiable {
        case head(String, cli: String?)
        case model(AgentModel, recent: Bool)
        case note(String)

        var id: String {
            switch self {
            case .head(let title, _): return "h:" + title
            case .model(let model, let recent): return (recent ? "r:" : "m:") + model.id
            case .note(let words): return "n:" + words
            }
        }
    }

    // MARK: what it lists

    private var lines: [Line] {
        let hidden = ModelDefaults.shared.hidden
        let chosen = request.choice
        func shown(_ models: [AgentModel]) -> [AgentModel] {
            models.filter { !hidden.contains($0.id) || (chosen.cli == $0.cli && chosen.model == $0.model) }
        }
        let words = query.lowercased().split(separator: " ")
        func matches(_ model: AgentModel) -> Bool {
            let text = (model.name + " " + AgentModels.agentName(model.cli) + " " + AgentSetupModel.tool(model.cli) + " " + ModelPicker.planName(model.cli)).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        var out: [Line] = []
        var every: [AgentModel] = []
        if request.offersMac { every.append(AgentModels.mac) }
        for cli in request.clis { every += shown(AgentPlan.of(cli)?.models ?? []) }
        if words.isEmpty {
            let recent = ModelPicker.recent.compactMap { id in every.first { $0.id == id } }.prefix(3)
            if !recent.isEmpty {
                out.append(.head("Recently Used", cli: nil))
                out += recent.map { .model($0, recent: true) }
            }
        }
        if request.offersMac, matches(AgentModels.mac) {
            out.append(.model(AgentModels.mac, recent: false))
        }
        for cli in request.clis {
            let models = shown(AgentPlan.of(cli)?.models ?? []).filter(matches)
            guard !models.isEmpty || words.isEmpty else { continue }
            out.append(.head(ModelPicker.planName(cli), cli: cli))
            if !AgentModels.here(cli) {
                out.append(.note("Connect \(AgentModels.agentName(cli)) in Settings › AI › Models to use these."))
            } else if models.isEmpty {
                out.append(.note(ModelField.emptyWords(cli, allHidden: false)))
            } else {
                out += models.map { .model($0, recent: false) }
            }
        }
        if out.isEmpty, !words.isEmpty {
            out.append(.note("No model called \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}"))
        }
        return out
    }

    private var models: [AgentModel] {
        lines.compactMap { if case .model(let model, _) = $0 { return model } else { return nil } }
    }

    private var current: AgentModel? {
        let all = models
        return all.indices.contains(spot) ? all[spot] : nil
    }


    // MARK: the view

    var body: some View {
        // The list alone in the middle; what the model is, held to its
        // right, out of the centering.
        list
            .overlay(alignment: .topTrailing) {
                if info, cardFits, let model = current {
                    ModelInfo(model: model)
                        .frame(width: Self.side)
                        .modifier(PickerPlate())
                        .offset(x: Self.side + Self.gap)
                        .transition(.opacity.combined(with: .offset(x: -6)))
                }
            }
            .offset(x: -shift)
        .animation(Motion.chatQuick, value: info)
        .animation(Motion.chatQuick, value: shift)
        .onAppear {
            // Up on the one in use, in its plan's place, its effort with it.
            let ids = modelLineIDs
            if let chosen = models.first(where: isChosen) {
                spot = ids.firstIndex(of: "m:" + chosen.id) ?? ids.firstIndex(of: "r:" + chosen.id) ?? 0
            }
            scrollTo = spotLineID.map { "open:" + $0 }
            effort = PickerEffort(picked: request.choice.effort)
            if !request.query.isEmpty { query = request.query }
        }
        .onChange(of: query) { _, _ in spot = 0 }
        // Identity comes from the agents' files. Usage is read without a
        // model request, including blocked plans reset outside Yab.
        .task {
            // The environment tasks run in when known (AgentLaunch), so an
            // account read here is read as its task would be.
            guard let found = Shell.cachedTerminal ?? Shell.cached else { return }
            if !ModelPicker.looked {
                ModelPicker.looked = true
                await accounts.look(found)
            }
            await accounts.ask(request.clis, found: found, refreshBlocked: true)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PickerSearch(text: $query, placeholder: "Search models\u{2026}",
                             move: move, side: turn, pick: take, close: { browser.modelPicker = nil })
                    .frame(height: 22)
                Button { info.toggle(); ModelPicker.infoShown = info } label: { Symbol("info.circle", size: 14) }
                    .buttonStyle(.yab(info ? .secondary : .quiet, .small, icon: .square))
                    .focusable(false)
                    .keyTip(info ? "Hide details" : "Show details")
            }
            .padding(.leading, 16)
            .padding(.trailing, 10) // design: the info button sits in from the edge by its own plate, the words by the list's inset
            .frame(height: 48)
            Rectangle().fill(Palette.ink.opacity(0.07)).frame(height: 1)
            ScrollViewReader { reader in
                ThreadScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(request.title)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(lines) { line in
                            switch line {
                            case .head(let title, let cli):
                                ModelPlanHead(title: title, cli: cli)
                            case .model(let model, _):
                                let hot = spotLineID == line.id
                                ModelPickerRow(model: model, chosen: isChosen(model), hot: hot,
                                               dim: model.cli != "mac" && !accounts.hasRoom(model.cli),
                                               effort: hot ? effort.on(model) : nil) {
                                    spot = modelIndex(of: line)
                                    take()
                                }
                                .id(line.id)
                                .onHover { inside in if inside { spot = modelIndex(of: line) } }
                            case .note(let words):
                                Text(words)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Palette.muted)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                // Opening, the one in use in the middle; by the keys, only
                // as far as brings the row into view.
                .onChange(of: scrollTo) { _, id in
                    guard let id else { return }
                    if id.hasPrefix("open:") { reader.scrollTo(String(id.dropFirst(5)), anchor: .center) } else { reader.scrollTo(id) }
                }
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: Self.height)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PickerPlate())
    }

    // Lines and models: a recent model is listed twice, once in each place.
    private var modelLineIDs: [String] {
        lines.compactMap { if case .model = $0 { return $0.id } else { return nil } }
    }
    private var spotLineID: String? {
        let ids = modelLineIDs
        return ids.indices.contains(spot) ? ids[spot] : nil
    }
    private func modelIndex(of line: Line) -> Int { modelLineIDs.firstIndex(of: line.id) ?? 0 }

    /// The one in use; with no model of its own, the plan's default,
    /// the first its agent lists.
    private func isChosen(_ model: AgentModel) -> Bool {
        guard request.choice.cli == model.cli else { return false }
        if model.cli == "mac" { return true }
        if let chosen = request.choice.model { return chosen == model.model }
        return AgentPlan.of(model.cli)?.models.first?.id == model.id
    }

    // MARK: keys

    private func move(_ by: Int) {
        let count = modelLineIDs.count
        guard count > 0 else { return }
        spot = (spot + by + count) % count
        scrollTo = spotLineID
    }

    /// ← → : the effort of the model under the pointer, Auto first.
    private func turn(_ by: Int) {
        guard let model = current else { return }
        effort.turn(model, by: by)
    }

    private func take() {
        guard let model = current else { return }
        let choice = ModelChoice(cli: model.cli, model: model.model.isEmpty ? nil : model.model, effort: effort.on(model))
        ModelPicker.used(model)
        browser.modelPicker = nil
        request.pick(choice)
    }

    // MARK: kept between times

    static var infoShown: Bool {
        get { Store.settings.object(forKey: "models.picker.info") as? Bool ?? true }
        set { Store.settings.set(newValue, forKey: "models.picker.info") }
    }

    /// Whether the plans' accounts were asked who they are yet.
    static var looked = false

    static var recent: [String] { Store.settings.stringArray(forKey: "models.recent") ?? [] }

    static func used(_ model: AgentModel) {
        var list = recent.filter { $0 != model.id }
        list.insert(model.id, at: 0)
        Store.settings.set(Array(list.prefix(6)), forKey: "models.recent")
    }

    /// "Claude Subscription", as the plan is named in Settings.
    static func planName(_ cli: String) -> String {
        AgentPlan.of(cli)?.group ?? "On This Mac"
    }
}

/// A plan's head: its name, and at its end how much of it is used, in
/// words and a short bar, each window in words on a click.
struct ModelPlanHead: View {
    let title: String
    let cli: String?
    /// Its words' size: the picker's 12, Settings' smaller list 11.
    var size: CGFloat = 12
    @ObservedObject private var accounts = PlanAccounts.shared

    /// Its accounts: those signed in, and the CLI's usual one always.
    private var every: [PlanAccount] {
        guard let cli, cli != "mac" else { return [] }
        return accounts.all(cli).filter { $0.usual || !accounts.signedOut.contains($0.id) }
    }

    var body: some View {
        let every = every
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                // One account: whose it is, beside the plan's name.
                if every.count == 1, let account = every.first, let who = ModelPlanHead.who(account) {
                    Text(who)
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if every.count == 1, let account = every.first { PlanRoom(account: account) }
            }
            // Several: each on a line of its own, the one tasks start on said.
            if every.count > 1 {
                let next = cli.flatMap { accounts.pick($0) }
                ForEach(every) { account in
                    HStack(spacing: 8) {
                        Text(ModelPlanHead.who(account) ?? "Another account")
                            .foregroundStyle(account.id == next?.id ? Palette.ink.opacity(0.75) : Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if account.id == next?.id {
                            Text("In use").foregroundStyle(Palette.faint)
                        }
                        Spacer(minLength: 8)
                        PlanRoom(account: account)
                    }
                }
            }
        }
        .font(.system(size: size))
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// "Max · sam@42nd.dev": its plan and who it is signed in as.
    @MainActor static func who(_ account: PlanAccount) -> String? {
        let plan = account.plan.map { PlanAccounts.tier(account.cli, $0) }
        let parts = [plan, account.email].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// "52% used", or "Out until Fri 10 PM"; nil before the plan has said.
    @MainActor static func words(_ id: String, now: Date = Date()) -> String? {
        let accounts = PlanAccounts.shared
        if accounts.out(id, now: now), let until = accounts.quotas[id]?.out { return "Out until " + PlanAccounts.when(until, now: now) }
        guard let used = accounts.fullest(id, now: now) else { return nil }
        return "\(Int((used * 100).rounded()))% used"
    }
}

/// How much of one account's plan is used, in words and a short bar; each
/// window on a click.
private struct PlanRoom: View {
    let account: PlanAccount
    @ObservedObject private var accounts = PlanAccounts.shared
    @State private var open = false

    var body: some View {
        let used = accounts.fullest(account.id)
        let out = accounts.out(account.id)
        let tint: Color = out ? ButtonCSS.danger : (used ?? 0) >= 0.9 ? Color.orange : Palette.muted
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                // Cursor never says its usage: where to see it, not "yet".
                Text(ModelPlanHead.words(account.id) ?? (account.cli == "cursor" ? "Usage on cursor.com" : "No usage yet"))
                    .foregroundStyle(used == nil ? Palette.faint : tint)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                if let used {
                    Capsule().fill(Palette.ink.opacity(0.1))
                        .frame(width: 40, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint).frame(width: 40 * max(0.04, min(1, used)), height: 4)
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyTip("How much of the plan is used")
        .popover(isPresented: $open, arrowEdge: .bottom) { QuotaDetails(account: account) }
    }
}

/// One model: its mark, its name, and at its end what it is good for; the
/// one in use ticked; under the pointer, its effort.
private struct ModelPickerRow: View {
    let model: AgentModel
    let chosen: Bool
    let hot: Bool
    let dim: Bool
    let effort: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Symbol(FieldAnswer.mark(model.cli), size: 13)
                    .foregroundStyle(Palette.ink)
                    .frame(width: 16)
                Text(model.name)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if hot, !model.efforts.isEmpty {
                    Text((effort.map(AgentModels.effortTitle) ?? "Auto") + " effort")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink.opacity(0.75))
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Palette.ink.opacity(0.07), in: Capsule())
                } else {
                    Text(ModelPickerRow.hint(model))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                if chosen {
                    Symbol("checkmark", size: 10, weight: .semibold)
                        .foregroundStyle(Palette.ink)
                }
            }
            .font(.system(size: 13.5))
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Palette.ink.opacity(hot ? 0.07 : 0), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
            .opacity(dim ? 0.88 : 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    /// What it is good for, in two or three words.
    static func hint(_ model: AgentModel) -> String {
        switch model.id {
        case "mac:": return "Free, private"
        case "claude:fable": return "Most capable"
        case "claude:opus": return "Long, hard tasks"
        case "claude:sonnet": return "Most work"
        case "claude:haiku": return "Fastest"
        default:
            // A plan's own words, when they are few enough for the row.
            let about = model.about.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return about.split(separator: " ").count <= 4 ? about : ""
        }
    }
}

/// Beside the list: what the model under the pointer is, in a line of
/// its agent's words and a few marks, and how much of its plan is used.
private struct ModelInfo: View {
    let model: AgentModel
    @ObservedObject private var accounts = PlanAccounts.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Symbol(FieldAnswer.mark(model.cli), size: 13.5)
                Text(model.name).font(.system(size: 13.5, weight: .semibold))
            }
            Text(model.cli == "mac" ? "On this Mac: free, and nothing leaves it. For short text."
                 : model.about.isEmpty ? "Runs on your \(AgentModels.agentName(model.cli)) plan." : model.about)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            let marks = ModelInfo.marks(model)
            if !marks.isEmpty {
                // What it can do, as a row of words.
                HStack(spacing: 4) {
                    ForEach(marks, id: \.self) { mark in
                        Text(mark)
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 6)
                            .frame(height: 20)
                            .background(Palette.ink.opacity(0.06), in: Capsule())
                    }
                }
            }
            if model.cli != "mac", let account = accounts.pick(model.cli) {
                let windows = accounts.windows(account.id)
                ForEach(windows, id: \.name) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(PlanAccounts.named(item.name).title)
                            Spacer()
                            Text("\(Int((item.window.used * 100).rounded()))%"
                                 + (item.window.resets.map { " \u{00B7} " + PlanAccounts.when($0) } ?? ""))
                                .foregroundStyle(Palette.muted)
                                .monospacedDigit()
                        }
                        Capsule().fill(Palette.ink.opacity(0.08)).frame(height: 3)
                            .overlay(alignment: .leading) {
                                GeometryReader { box in
                                    Capsule().fill(item.window.used >= 0.9 ? Color.orange : Palette.ink.opacity(0.5))
                                        .frame(width: box.size.width * max(0.03, min(1, item.window.used)))
                                }
                            }
                    }
                }
            }
        }
        .font(.system(size: 12))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "272K", "Images", "Reasoning", "Fast".
    static func marks(_ model: AgentModel) -> [String] {
        var out: [String] = []
        if let context = model.context { out.append(context >= 1_000_000 ? "\(context / 1_000_000)M" : "\(context / 1000)K") }
        if model.vision { out.append("Images") }
        if !model.efforts.isEmpty { out.append("Reasoning") }
        if model.fast { out.append("Fast") }
        return out
    }
}

/// The picker's search: a bare field that takes the keyboard at once, the
/// arrows moving through the list and changing effort, ↩ taking, Esc away.
struct PickerSearch: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let move: (Int) -> Void
    let side: (Int) -> Void
    let pick: () -> Void
    let close: () -> Void
    /// The words' size: the model picker's large search, a list's smaller.
    var size: CGFloat = 15
    /// A search revealed by the first typed letter continues after it.
    /// Other pickers retain AppKit’s usual selection on focus.
    var beginsAtEnd = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = Field()
        field.beginsAtEnd = beginsAtEnd
        field.isAutomaticTextCompletionEnabled = false
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: size)
        field.textColor = NSColor(Palette.ink)
        field.placeholderString = placeholder
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            if field.beginsAtEnd { field.take() } else { field.window?.makeFirstResponder(field) }
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    /// Takes the keyboard as soon as it is in a window, and again when that
    /// window becomes key, so the first letter typed after the picker opens
    /// lands in it. SwiftUI makes the field before
    /// it is in a window, and a list's own window is made key after its
    /// field is made, so a single try at making it can miss.
    final class Field: NSSearchField {
        private var keyWatch: NSObjectProtocol?
        var beginsAtEnd = false
        private var placedInitialCaret = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyWatch { NotificationCenter.default.removeObserver(keyWatch) }
            keyWatch = nil
            guard let window else { return }
            take()
            keyWatch = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.take() }
            }
        }

        /// The field's own editor in front, unless it already is.
        func take() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                if !self.isEditing(in: window) { window.makeFirstResponder(self) }
                if self.beginsAtEnd, !self.placedInitialCaret, self.isEditing(in: window),
                   let editor = window.firstResponder as? NSTextView {
                    self.placedInitialCaret = true
                    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                }
            }
        }

        func isEditing(in window: NSWindow) -> Bool {
            (window.firstResponder as? NSText)?.delegate === self
        }

        deinit {
            if let keyWatch { NotificationCenter.default.removeObserver(keyWatch) }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PickerSearch
        init(_ parent: PickerSearch) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.moveLeft(_:)) where textView.string.isEmpty: parent.side(-1)
            case #selector(NSResponder.moveRight(_:)) where textView.string.isEmpty: parent.side(1)
            case #selector(NSResponder.insertNewline(_:)): parent.pick()
            case #selector(NSResponder.cancelOperation(_:)): parent.close()
            default: return false
            }
            return true
        }
    }
}

/// The picker's ground: the ⌘J field's own, Liquid Glass over a
/// material, tinted with the ground (Omnibox), or the ground itself where
/// glass is not drawn.
struct PickerPlate: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var solid

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.floating, style: .continuous)
        content
            .clipShape(shape)
            .background {
                if #available(macOS 26.0, *), !solid {
                    shape.fill(.regularMaterial)
                    Color.clear.glassEffect(.regular.tint(Palette.ground.opacity(Omnibox.glassTint)), in: shape)
                } else {
                    shape.fill(Palette.ground) // design: the field's own card without glass, as Omnibox draws it
                        .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1)) // design: the field's own card without glass
                        .shadow(color: .black.opacity(0.18), radius: 30, y: 12) // design: lifted over the field's card, as ⌘K's list is
                }
            }
    }
}
