import SwiftUI

struct MailCodeChip: View {
    let item: MailCodeItem
    var size: CGFloat = 12
    @ObservedObject private var codes = MailCodeState.shared
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        let state = codes.state(item)
        let since = codes.copyTimes[item.id]
        Button { codes.copy(item) } label: {
            ZStack { Text(item.read.shown).hidden(); Text("Copied").hidden() }
                .overlay {
                    if let since {
                        TimelineView(.animation) { clock in
                            let age = clock.date.timeIntervalSince(since)
                            let copied = age >= 0 && age < 1.2
                            let progress = reduced ? 1 : min(1, max(0, (copied ? age : age - 1.2) / 0.18))
                            ZStack {
                                Text(item.read.shown).strikethrough(state == .expired || state == .used)
                                    .offset(y: reduced ? 0 : copied ? -size * 1.7 * progress : size * 1.7 * (1 - progress))
                                    .opacity(copied ? 1 - progress : progress)
                                Text("Copied")
                                    .offset(y: reduced ? 0 : copied ? size * 1.7 * (1 - progress) : -size * 1.7 * progress)
                                    .opacity(copied ? progress : 1 - progress)
                            }
                        }
                    } else {
                        Text(item.read.shown).strikethrough(state == .expired || state == .used)
                    }
                }
                .font(.system(size: size, weight: .medium, design: .monospaced))
                .foregroundStyle(state == .expired || state == .used ? Palette.muted : Palette.ink)
                .padding(.horizontal, size > 20 ? 12 : 6)
                .padding(.vertical, size > 20 ? 12 : 4)
                .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.control))
                .clipped()
        }
        .buttonStyle(PressStyle())
        .focusable(false)
        .pointerStyle(.link)
        .keyTip(state == .expired ? "Expired at " + item.expires.englishFormatted(date: .omitted, time: .shortened) : "Copy", keys: "⌘C")
        .accessibilityLabel("Copy code " + item.read.shown)
    }
}

struct MailCodeRow: View {
    let item: MailCodeItem
    @ObservedObject private var codes = MailCodeState.shared
    var body: some View {
        HStack(spacing: 6) {
            MailCodeChip(item: item)
            let state = codes.state(item)
            if state != .expired {
                Text((state == .used ? "entered" : state == .copied ? "copied" : "\(max(1, Int(ceil(item.expires.timeIntervalSinceNow / 60))))m") + " ·")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(state == .fresh ? Color.orange : Palette.muted)
                    .lineLimit(1)
            }
        }
    }
}
