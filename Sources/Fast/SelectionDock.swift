import SwiftUI

/// Content only. AgentDock owns the one persistent plate, its face,
/// measured size, corners and transitions through running/result/receipt.
struct SelectionDockContent: View {
    @ObservedObject var commands: SelectionCommands
    @ObservedObject var tab: Tab

    static func expanded(_ commands: SelectionCommands) -> Bool {
        commands.showsDockResult || (commands.stage == .failed && !commands.noChange)
    }

    static func pose(_ commands: SelectionCommands) -> FacePose {
        if commands.receipt == .replaced || commands.receipt == .restored || commands.receipt == .copied { return .done }
        if commands.stage == .failed { return commands.noChange ? .watch : .stuck }
        return commands.stage == .running || commands.applying ? .think : .watch
    }

    private var words: String {
        if let receipt = commands.receipt { return receipt.rawValue }
        if commands.applying { return "Replacing…" }
        if commands.stage == .running { return "Rewriting…" }
        if commands.stage == .failed { return commands.noChange ? "Nothing to change" : "Couldn’t finish" }
        return "Result"
    }

    private var width: CGFloat { max(160, min(456, (tab.builtPage?.bounds.width ?? 480) - 24)) }

    static func displayText(_ commands: SelectionCommands) -> AttributedString {
        if commands.stage == .failed { return AttributedString(commands.error) }
        if SelectionCommands.rewrites(commands.command, editable: commands.snapshot?.editable == true) {
            return AttributedString(commands.output)
        }
        return AgentAnswer.rich(commands.output)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if Self.expanded(commands) {
                ThreadScrollView {
                    Text(Self.displayText(commands))
                        .font(.system(size: 13.5))
                        .foregroundStyle(commands.stage == .failed ? ButtonCSS.danger : Palette.ink)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .padding(CardFrame.inset)
            }
            HStack(spacing: 10) {
                // The shared face stays anchored in AgentDock's overlay.
                Color.clear.frame(width: 15, height: 15).padding(.leading, 12)
                Text(words)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .id(words)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 6)),
                        removal: .opacity.combined(with: .offset(y: -6)).animation(.easeIn(duration: 0.1))
                    ))
                if Self.expanded(commands) { Spacer(minLength: 8) }
                actions
            }
            .frame(height: 36)
            .padding(.trailing, 6)
        }
        .frame(width: Self.expanded(commands) ? width : nil, alignment: .leading)
        .animation(Motion.reshape, value: words)
        .animation(Motion.reshape, value: commands.receipt)
        .accessibilityIdentifier("selection-command-dock")
        .benchSpot("selection command dock")
    }

    @ViewBuilder private var actions: some View {
        if commands.stage == .running || commands.applying {
            Button { commands.cancelCommand() } label: {
                HStack(spacing: 6) {
                    Text("Cancel")
                        .fixedSize()
                    KeyGlyphs(keys: "esc", size: 11.5, tint: nil, rest: 0.6)
                }
            }
            .disabled(commands.applying)
            .buttonStyle(.yab(.secondary, .regular))
            .benchSpot("command cancel")
        } else if commands.receipt == .replaced {
            Button { commands.undoReplacement() } label: {
                HStack(spacing: 6) {
                    Text("Undo")
                        .fixedSize()
                    KeyGlyphs(keys: "⌘Z", size: 11.5, tint: nil, rest: 0.6)
                }
            }
            .buttonStyle(.yab(.secondary, .regular))
            .benchSpot("command undo")
        } else if commands.receipt == nil {
            Button("Dismiss") { commands.close() }
                .buttonStyle(.yab(.quiet, .regular))
                .benchSpot("command dismiss")
            if commands.stage == .preview, let snap = commands.snapshot {
                Button(commands.canReplace(snap) ? "Replace" : "Copy") { commands.apply() }
                    .buttonStyle(.yab(.primary, .regular))
                    .benchSpot("command apply")
            } else if commands.stage == .failed, !commands.output.isEmpty {
                Button("Copy") { commands.copyResult() }
                    .buttonStyle(.yab(.primary, .regular))
            }
        }
    }
}
