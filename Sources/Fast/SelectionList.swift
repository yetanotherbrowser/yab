import SwiftUI

/// The command list and result card live in the page's own coordinates.
struct SelectionLayer: View {
    @ObservedObject var commands: SelectionCommands
    @ObservedObject private var macModel = AppleModelControl.shared
    let tab: Tab
    @State private var keeping = false
    @State private var commandName = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The list's or card's own height as drawn: where it goes, above the
    /// selection or below, is decided on this rather than on a guess.
    @State private var panelHeight: CGFloat = 0
    @State private var answerHeight: CGFloat = 0

    var body: some View {
        GeometryReader { room in
            if macModel.enabled, let hint = commands.hint, tab === commands.hintTab, commands.stage == .closed {
                Button {
                    // It says Improve, so it improves, in place.
                    commands.open(on: tab, command: commands.commands.contains { $0.id == "improve" && $0.enabled } ? "improve" : nil)
                } label: {
                    HStack(spacing: 6) {
                        Symbol("sparkles", size: 12)
                        Text("Improve")
                        ShortcutGlyphs(.agentAsk, size: 11.5, tint: Palette.muted)
                    }
                    .font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .barFrame()
                .position(x: min(max(hint.rect.maxX, 60), max(60, room.size.width - 60)),
                          y: min(hint.rect.maxY + 22, room.size.height - 22))
                // Pressed, it becomes the result's bar in its place (SelectionInk).
                .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
            // An answer in the ⌘J field is the field's (FieldAnswer); one on
            // its way from there into the page shows here only if the page
            // turns it down.
            let shown = commands.snapshot.flatMap { snap -> SelectionSnapshot? in
                guard commands.stage != .closed, tab === commands.activeTab, !commands.answering, !commands.docked,
                      !(commands.handing && commands.stage == .preview) else { return nil }
                return snap
            }
            // A rewrite, in the text's own place; anything else on a card.
            let ink = shown.flatMap { snap in
                SelectionCommands.rewrites(commands.command, editable: snap.editable)
                    && SelectionInk.fits(snap, room: room.size) ? snap : nil
            }
            SelectionInk(commands: commands, snap: ink, room: room.size, tab: tab)
            if let snap = shown, ink == nil, !commands.replacing {
                let width = max(0, min(420.0, room.size.width - 24))
                let height = panelHeight > 0 ? panelHeight : 220.0
                let x = min(max(snap.rect.minX + width / 2, width / 2 + 12),
                            max(width / 2, room.size.width - width / 2 - 12))
                let below = snap.rect.maxY + height + 12 <= room.size.height
                let y = below ? snap.rect.maxY + 8 + height / 2
                    : max(height / 2 + 12, snap.rect.minY - 8 - height / 2)
                content(snap, width: width)
                    .frame(width: width)
                    .background(GeometryReader { size in
                        Color.clear.preference(key: SelectionPanelHeight.self, value: size.size.height)
                    })
                    .onPreferenceChange(SelectionPanelHeight.self) { panelHeight = $0 }
                    .position(x: x, y: y)
                    .onChange(of: commands.stage) { _, _ in panelHeight = 0 }
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : SelectionInk.spring, value: commands.stage == .closed)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : SelectionInk.spring, value: commands.hint == nil)
        .sheet(isPresented: $keeping) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Keep as command").font(.system(size: 17, weight: .semibold))
                TextField("Name", text: $commandName)
                Text(commands.command?.prompt ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                HStack {
                    Spacer()
                    Button("Cancel") { keeping = false }
                        .buttonStyle(.yab(.secondary, .regular))
                    Button("Save") {
                        commands.keepCurrent(as: commandName)
                        keeping = false
                    }
                    .buttonStyle(.yab(.primary, .regular))
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    /// An answer that doesn't go back into the text, an explanation, a
    /// summary: on a card, its words and its buttons, no quote of what was
    /// selected over them and no heading. Where it ran is the words' tip.
    @ViewBuilder
    private func content(_ snap: SelectionSnapshot, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: CardFrame.buttonGap) {
            // As tall as the words, up to 160, and only then scrolling:
            // a short answer has no empty card around it. A frame with
            // only a most would take all 160 and float the words in it.
            ThreadScrollView {
                answer.background(GeometryReader { size in
                    Color.clear.preference(key: SelectionAnswerHeight.self, value: size.size.height)
                })
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(answerHeight, 20), 160))
            .onPreferenceChange(SelectionAnswerHeight.self) { answerHeight = $0 }
            .pointerTip(commands.command.map(source) ?? "")
            HStack(spacing: 8) {
                Button(commands.noChange ? "Close" : "Back") {
                    if commands.noChange { commands.close() } else { commands.back() }
                }
                    .buttonStyle(.yab(.quiet, CardFrame.button))
                Spacer()
                // The chat in full, the card becoming the column.
                if commands.hasChat {
                    Button { Agents.shared.browser?.expandAnswer() } label: {
                        HStack(spacing: 6) {
                            Symbol("square.arrow.out", size: 12)
                            Text("Open in Chat")
                        }
                    }
                    .buttonStyle(.yab(.quiet, CardFrame.button))
                    .keyTip("This chat in full, in the column beside the page")
                }
                if commands.stage == .preview, commands.command?.id == "ask" {
                    Button("Keep as Command") {
                        commandName = commands.command?.prompt
                            .split(separator: " ").prefix(4).joined(separator: " ") ?? ""
                        keeping = true
                    }
                    .buttonStyle(.yab(.quiet, CardFrame.button))
                }
                // Copy once: not beside a main button that already copies.
                if (commands.stage == .preview && primary(snap) != "Copy") || (commands.stage == .failed && !commands.output.isEmpty) {
                    Button("Copy") { commands.copy() }
                    .buttonStyle(.yab(.secondary, CardFrame.button))
                }
                if commands.stage == .failed, commands.command?.executor == "mac", !commands.noChange {
                    Button("Ask " + commands.retryName) {
                        commands.retryWithAgent()
                    }
                    .buttonStyle(.yab(.primary, CardFrame.button))
                }
                if commands.stage == .preview, let command = commands.command {
                    Button("Again") { commands.run(command) }
                    .buttonStyle(.yab(.secondary, CardFrame.button))
                    Button(primary(snap)) { commands.apply() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.yab(.primary, CardFrame.button))
                }
            }
            .font(.system(size: CardFrame.words))
        }
        .frame(width: max(0, width - CardFrame.inset * 2))
        .cardFrame()
        // Where Open in Chat takes off from (ChatFlight).
        .background(FlightMark(kind: .answer, corner: Radius.card))
        .pageScheme(dark: snap.dark)
    }

    @ViewBuilder
    private var answer: some View {
        if commands.stage == .running && commands.output.isEmpty {
            Shimmer(text: "Working on the selection…", size: 13.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(SelectionDockContent.displayText(commands))
                .font(.system(size: 13.5))
                .foregroundStyle(commands.stage == .failed ? ButtonCSS.danger : Palette.ink)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Where it runs, as it would now (SelectionCommands.runner): a Mac
    /// without its model, or a selection too long for it, says the agent
    /// here, and one with neither says where to get one.
    private func source(_ command: SelectionCommand) -> String {
        let privateAgent = tab.shy ? " · leaves this Mac" : ""
        switch commands.runner(command) {
        case nil: return "Connect an agent"
        case "mac": return "on this Mac"
        case let cli? where AgentPlan.isPlan(cli): return commands.agentTitle(command) + privateAgent
        default: return ""
        }
    }

    private func primary(_ snap: SelectionSnapshot) -> String {
        switch commands.command?.id {
        case "calendar": return "Add"
        case "map": return "Open Maps"
        case "call": return "Call"
        default: break
        }
        if commands.command?.result == "draft" { return "Insert" }
        return commands.canReplace(snap) ? "Replace" : "Copy"
    }

    /// Each command its own mark, all Central's (Glyphs.swift): no two
    /// commands wear the same one. The field's rows wear the same.
    static func symbol(_ id: String) -> String {
        switch id {
        case "improve": return "yab.text.spark"
        case "fix": return "yab.text.check"
        case "shorter": return "yab.text.minus"
        case "longer": return "yab.text.plus"
        case "formal": return "yab.suitcase"
        case "friendly": return "yab.smile"
        case "translate": return "yab.translate"
        case "define": return "yab.book"
        case "explain": return "yab.text.question"
        case "summarize": return "yab.doc.spark"
        case "explain-code": return "yab.code.spark"
        case "find-bugs": return "yab.bug"
        case "quote": return "yab.copyframe.quote"
        case "calendar": return "yab.calendar.plus"
        case "map": return "yab.map"
        case "call": return "yab.phone"
        case "convert": return "yab.calculator"
        case "ask-task": return "agent.face"
        default: return "bubble.sparkle"
        }
    }
}

private struct SelectionAnswerHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct SelectionPanelHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
