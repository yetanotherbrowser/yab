import AppKit
import SwiftUI

// The chat's own lines in a turn, read from the provider stream:
// neither your words nor the agent's, so never a
// bubble. A divider where the context was compacted, a quiet line (you
// stopped it, a model switched, a background task done, another
// session's message), where it stands (out of room), an error, a notice,
// the files it sent you; its thoughts folded; a subagent's report; text
// you pasted, as a chip.

/// One of the chat's own lines (ChatItem.notes), by its name.
struct ChatNote: View {
    let item: ChatItem

    var body: some View {
        switch item.name {
        case "compacted":
            // A thin divider across the turn, never a message.
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
        case "status":
            HStack(spacing: 8) {
                Circle().fill(Palette.muted).frame(width: 6, height: 6)
                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink.opacity(0.75))
            }
            .padding(.leading, MessageBubble.words)
            .pointerTip(item.extra?["raw"] ?? item.text)
        case "error":
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StepMark(art: .fail, tint: ButtonCSS.danger)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                    if let raw = item.extra?["raw"], raw != item.text {
                        Text(raw)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, MessageBubble.words)
        case "sent":
            ChatSent(item: item)
                .padding(.leading, MessageBubble.words)
        default:
            // "note" and "notice": one quiet line.
            Text(item.text)
                .font(.system(size: 12.5))
                .foregroundStyle(item.extra?["failed"] != nil ? ButtonCSS.danger : Palette.muted)
                .lineLimit(item.name == "notice" ? 3 : 2)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .padding(.leading, MessageBubble.words)
        }
    }
}

/// What it sent you with SendUserFile: its caption, and each file not a
/// picture as a chip that opens it. Its pictures stand under the turn.
private struct ChatSent: View {
    let item: ChatItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.text.isEmpty {
                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            let files = (item.extra?["files"] ?? "").split(separator: "\n").map(String.init)
            if !files.isEmpty { ChatFileCards(paths: files) }
        }
    }
}

/// Its thoughts, folded: "Thought for 12s", their words when opened.
struct ChatThought: View {
    let items: [ChatItem]
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var still

    /// How long it thought, all told, in seconds.
    static func seconds(_ items: [ChatItem]) -> Double {
        items.reduce(0) { $0 + (Double($1.extra?["ms"] ?? "") ?? 0) } / 1000
    }

    /// "Thought for 12s", or "Thought" with no time kept.
    static func words(_ items: [ChatItem]) -> String {
        let seconds = seconds(items)
        return seconds >= 1 ? "Thought for " + Chat.span(seconds) : "Thought"
    }

    var body: some View {
        let text = items.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        VStack(alignment: .leading, spacing: 4) {
            let line = HStack(spacing: 6) {
                Text(Self.words(items))
                if !text.isEmpty {
                    Symbol("chevron.right", size: 9.5, weight: .semibold)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Palette.muted)
            .contentShape(Rectangle())
            if text.isEmpty {
                line
            } else {
                Button { withAnimation(still ? nil : Motion.chatQuick) { open.toggle() } } label: { line }
                    .buttonStyle(.plain)
                    .keyTip(open ? "Hide its thinking" : "Show its thinking")
                    .accessibilityValue(open ? "Expanded" : "Collapsed")
            }
            if open, !text.isEmpty {
                Text(AgentAnswer.rich(text))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .transition(.opacity)
            }
        }
        .padding(.leading, MessageBubble.words)
    }
}

/// A subagent's report under its step: its first lines, the rest a click
/// away.
struct ChatReport: View {
    let text: String
    @State private var all = false

    static let first = 6

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let more = lines.count > Self.first
        VStack(alignment: .leading, spacing: 6) {
            Text(AgentAnswer.rich(all || !more ? text : lines.prefix(Self.first).joined(separator: "\n")))
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink.opacity(0.75))
                .lineSpacing(1)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if more {
                    Button(all ? "Show Less" : "Show All") { all.toggle() }
                        .buttonStyle(.yab(.secondary, .small))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// Text you pasted, as a chip over your words: "Pasted text · 412 lines".
struct ChatPasteChip: View {
    let text: String
    let open: Bool
    let toggle: () -> Void

    static func words(_ text: String) -> String {
        let count = AgentLines.lineCount(text)
        return "Pasted text \u{00B7} \(count) " + (count == 1 ? "line" : "lines")
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Symbol("doc.on.clipboard", size: 11).foregroundStyle(Palette.muted)
                Text(Self.words(text)).lineLimit(1)
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink.opacity(0.75))
            .padding(.horizontal, 6)
            .frame(maxWidth: 190, minHeight: 22)
            .background(Palette.ink.opacity(open ? 0.1 : 0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyTip(open ? "Hide the pasted text" : "Show the pasted text")
    }
}

/// The pasted text itself, opened from its chip.
struct ChatPasted: View {
    let text: String

    var body: some View {
        ThreadScrollView(.vertical) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Palette.ink.opacity(0.75))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .frame(maxHeight: 240)
        .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}
