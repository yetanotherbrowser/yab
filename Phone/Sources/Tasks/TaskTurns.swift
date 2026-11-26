import SwiftUI

/// What a task's chat says (taskTurnsHTML): what was asked, as the
/// question's bubble; the steps in words; what it waits for; its tabs in
/// their folder on the Mac as small sketches; and, done, the result. The
/// chat sheet (TaskChatSheet) holds it; the chats branch can hold it too.
struct TaskTurns: View {
    let run: TaskRun
    let def: TaskDefinition
    /// What stopped it, in the chat's words.
    var failure: String?
    /// The yes's waiting row: "Waiting for you: Pay €238".
    var waiting: String?
    /// Who sent the code: "TAP".
    var codeSender: String?
    /// When the Mac fell asleep; nil when it just hasn't answered.
    var asleepSince: String?
    var retry: () -> Void = {}

    private typealias S = Metrics.Steps

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.TaskChat.turnGap) {
            QuestionBubble(text: def.ask)
                .frame(maxWidth: .infinity, alignment: .trailing)
            steps
            if !tabs.isEmpty { thumbs }
            if run.status == .done { done }
        }
    }

    // MARK: - steps

    /// The steps it reached: done ones with a tick, the one it works on in
    /// ink with a beating dot; a step it waits on (a code, a yes) in its
    /// running words without the dot; then what it waits for.
    private var steps: some View {
        VStack(alignment: .leading, spacing: S.gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                StepRow(row: row)
            }
            switch run.status {
            case .code:
                WaitRow(glyph: .key1, text: "Waiting for the code \(codeSender ?? "the site") sent to this \(DeviceWord.name)")
            case .yes:
                WaitRow(glyph: .creditCard1, text: waiting ?? "Waiting for you: \(def.yes ?? "a yes")")
            case .failed:
                WaitRow(glyph: .exclamationCircle, text: failure ?? def.failure ?? "It stopped") {
                    Button(action: retry) {
                        Text("Retry")
                            .font(.system(size: S.retryFont, weight: .semibold))
                            .tracking(-0.01 * S.retryFont)
                            .foregroundStyle(.white)
                            .padding(.horizontal, S.retryPadding)
                            .frame(height: S.retry)
                            .background(TaskInk.ink, in: Capsule(style: .continuous))
                            .frame(minHeight: Metrics.touch)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("task.retry")
                }
            case .waits:
                WaitRow(glyph: .macbook, text: asleepSince.map { "Waits for your Mac · asleep since \($0). It starts when the Mac wakes." }
                        ?? "Waits for your Mac · no answer yet. It starts when the Mac answers.", quiet: true)
            default:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.steps")
    }

    struct Row: Equatable {
        enum Kind: Equatable { case done, live }
        var icon: String
        var text: String
        var kind: Kind
    }

    /// Which steps show and how, the prototype's stepsDone: the steps it
    /// reached (0...k), the one it works on live with the beating dot while
    /// it runs or is being sent, every other ticked. A task that waits for a
    /// sleeping Mac it never took has nothing to show yet.
    var rows: [Row] {
        guard !def.steps.isEmpty else { return [] }
        let k = min(max(run.step, 0), def.steps.count - 1)
        let live = run.status == .running || run.status == .sending
        if run.status == .waits, k == 0 { return [] }
        return (0...k).map { i in
            let step = def.steps[i]
            return live && i == k ? Row(icon: step.icon, text: step.run, kind: .live) : Row(icon: step.icon, text: step.done, kind: .done)
        }
    }

    // MARK: - its tabs

    /// One tab per step reached, as the Mac opened them.
    private var tabs: [TaskDefinition.TaskTab] {
        let k = run.status == .done ? def.steps.count - 1 : max(run.step, 0)
        return Array(def.tabs.prefix(max(1, min(def.tabs.count, k + 1))))
    }

    private var thumbs: some View {
        VStack(alignment: .leading, spacing: Metrics.Thumbs.headGap) {
            Text("Its tabs, in a folder on your Mac")
                .font(.system(size: Metrics.Thumbs.headFont, weight: .semibold))
                .tracking(-0.01 * Metrics.Thumbs.headFont)
                .foregroundStyle(TaskInk.label)
                .frame(height: Metrics.Thumbs.headFont)
                .padding(.horizontal, Metrics.Thumbs.headInset)
            HStack(alignment: .top, spacing: Metrics.Thumbs.gap) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                    TabThumb(tab: tab)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.tabs")
    }

    // MARK: - done

    private var done: some View {
        VStack(alignment: .leading, spacing: Metrics.Done.gap) {
            Text("Done")
                .font(.system(size: Metrics.Thumbs.headFont, weight: .semibold))
                .tracking(-0.01 * Metrics.Thumbs.headFont)
                .foregroundStyle(TaskInk.label)
                .padding(.horizontal, Metrics.Thumbs.headInset)
            Text(Self.bold(def.resultLong ?? def.result))
                .font(.system(size: Metrics.Done.font))
                .tracking(-0.01 * Metrics.Done.font)
                .foregroundStyle(Ink.primary)
                .lineHeight(Metrics.Done.lineHeight, size: Metrics.Done.font)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.Done.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TaskInk.doneGround, in: RoundedRectangle(cornerRadius: Metrics.Done.radius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("task.done")
    }

    /// The result's <b>…</b> as bold.
    static func bold(_ html: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(html)
        while let open = rest.range(of: "<b>") {
            out += AttributedString(String(rest[..<open.lowerBound]))
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "</b>") else { break }
            var strong = AttributedString(String(rest[..<close.lowerBound]))
            strong.font = .system(size: Metrics.Done.font, weight: .semibold)
            out += strong
            rest = rest[close.upperBound...]
        }
        out += AttributedString(String(rest))
        return out
    }
}

/// One step: the site, the words, a tick or the beating dot.
struct StepRow: View {
    let row: TaskTurns.Row
    @State private var beat = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias S = Metrics.Steps

    private var shouldBeat: Bool {
        row.kind == .live && !Motion.disabled && !Motion.reduced && !reduceMotion
    }

    var body: some View {
        HStack(spacing: S.iconGap) {
            Favicon(icon: row.icon, size: S.icon)
            Text(row.text)
                .font(.system(size: S.font, weight: row.kind == .live ? .medium : .regular))
                .tracking(-0.01 * S.font)
                .foregroundStyle(row.kind == .live ? Ink.primary : Ink.rowGlyph)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch row.kind {
            case .done:
                Glyph(.checkmark1Small, size: S.check, color: TaskInk.tick)
            case .live:
                Circle()
                    .fill(Ink.primary)
                    .frame(width: S.dot, height: S.dot)
                    .scaleEffect(shouldBeat && beat ? 0.7 : 1)
                    .opacity(shouldBeat && beat ? 0.5 : 1)
                    // A stopped repeating transform needs a fresh render node.
                    // Replace only the dot, leaving the row and its layout intact.
                    .id(shouldBeat)
                    .padding(.trailing, S.dotTrailing)
            }
        }
        .frame(minHeight: S.row)
        .accessibilityElement(children: .combine)
        .onChange(of: shouldBeat, initial: true) { _, enabled in
            var transaction = Transaction(animation: enabled
                ? Motion.stepBeat.animation.repeatForever(autoreverses: true) : nil)
            transaction.disablesAnimations = !enabled
            withTransaction(transaction) { beat = enabled }
        }
    }
}

/// What it waits for: orange words, a glyph; a quiet gray one while the Mac sleeps.
struct WaitRow<Trailing: View>: View {
    let glyph: GlyphName
    let text: String
    var quiet = false
    @ViewBuilder var trailing: Trailing

    init(glyph: GlyphName, text: String, quiet: Bool = false, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.glyph = glyph
        self.text = text
        self.quiet = quiet
        self.trailing = trailing()
    }

    /// #C2410C: a step that waits for the person.
    static var orange: Color { TaskInk.needs }
    static var gray: Color { TaskInk.quiet }

    var body: some View {
        HStack(spacing: Metrics.Steps.iconGap) {
            Glyph(glyph, size: Metrics.Steps.icon, color: quiet ? Self.gray : Self.orange)
            Text(text)
                .font(.system(size: Metrics.Steps.font, weight: quiet ? .regular : .semibold))
                .tracking(-0.01 * Metrics.Steps.font)
                .foregroundStyle(quiet ? Ink.rowGlyph : Self.orange)
                .lineHeight(1.3, size: Metrics.Steps.font)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            trailing
        }
        .frame(minHeight: Metrics.Steps.row)
        // Contain, not combine: Retry stays a button of its own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.wait")
    }
}

/// A tab the Mac opened, drawn small: a search's lines, or a seat map's block.
struct TabThumb: View {
    let tab: TaskDefinition.TaskTab

    private typealias T = Metrics.Thumbs
    private static let ground = TaskInk.thumbGround
    private static let ink = TaskInk.thumbInk

    var body: some View {
        VStack(alignment: .leading, spacing: T.labelGap) {
            VStack(alignment: .leading, spacing: T.lineGap) {
                if tab.icon == "google" {
                    ForEach(0..<3, id: \.self) { _ in line }
                } else {
                    seats
                    line
                }
            }
            .padding(T.padding)
            .frame(width: T.width, height: T.sketch, alignment: .topLeading)
            .background(Self.ground, in: RoundedRectangle(cornerRadius: T.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: T.radius, style: .continuous).strokeBorder(Ink.outline.opacity(0.08), lineWidth: 0.5))
            HStack(spacing: T.labelGap) {
                Favicon(icon: tab.icon, size: T.icon)
                Text(tab.title)
                    .font(.system(size: T.font, weight: .medium))
                    .tracking(-0.01 * T.font)
                    .foregroundStyle(TaskInk.thumbLabel)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: T.width, alignment: .leading)
            .clipped()
        }
        .frame(width: T.width)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
    }

    private var line: some View {
        RoundedRectangle(cornerRadius: T.line / 2, style: .continuous)
            .fill(Self.ink)
            .frame(height: T.line)
    }

    /// A row of seats: 12 on, 4 off.
    private var seats: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            while x < size.width {
                let rect = CGRect(x: x, y: 0, width: min(12, size.width - x), height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 0), with: .color(Self.ink))
                x += 16
            }
        }
        .frame(height: T.seat)
        .clipShape(RoundedRectangle(cornerRadius: T.line / 2, style: .continuous))
    }
}
