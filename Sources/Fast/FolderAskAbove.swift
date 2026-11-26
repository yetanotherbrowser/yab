import AppKit
import SwiftUI
// design: file, a drawing of macOS's Files & Folders at its own sizes

// What opens above the line that asks for a closed folder (FolderAccess):
// what it is for, and the switch to turn on, drawn the way Files & Folders
// draws it. Two rows there can say Yab: the yab command, when it is
// installed, and Yab the app, whose switch this is. The drawing shows both,
// the command's row faded with a word saying it isn't the one.

struct FolderAskAbove: View {
    let ask: FolderAsk
    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            words
            if ask.stage != .folderOnly { picture }
            HStack(spacing: 6) {
                Text(ask.stage == .folderOnly ? ask.path : "Privacy & Security › Files & Folders")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(details ? "Less" : "Details") { details.toggle() }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
            if details {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ask.path).truncationMode(.middle)
                    Text("Read \(ask.checked.englishFormatted(date: .omitted, time: .standard)): \(ask.error)")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var words: some View {
        switch ask.stage {
        case .closed, .checking:
            Text(sentence(ask.reason) + " macOS keeps \(ask.place.name) closed to Yab, so turn it on for Yab.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        case .stillClosed:
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ask.place.name) is still closed to Yab.")
                    .foregroundStyle(ButtonCSS.danger)
                Text("The switch is under Yab, the app with this icon.")
                    .foregroundStyle(Palette.muted)
            }
            .font(.system(size: 12))
        case .folderOnly:
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ask.place.name) opens now, but \(ask.name) doesn't.")
                    .foregroundStyle(ButtonCSS.danger)
                Text("Choose it, and the task gets a copy of it.")
                    .foregroundStyle(Palette.muted)
            }
            .font(.system(size: 12))
        }
    }

    /// The agent's reason as a sentence.
    private func sentence(_ said: String) -> String {
        let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    // MARK: - the drawing

    private var picture: some View {
        VStack(spacing: 0) {
            if FileManager.default.fileExists(atPath: AgentSetup.shim.path) {
                row {
                    Symbol("terminal", size: 13)
                        .frame(width: 16, height: 16)
                    Text("yab").font(.system(size: 12, design: .monospaced))
                    Spacer(minLength: 8)
                    Text("the command, not this one").font(.system(size: 11))
                }
                .foregroundStyle(Palette.muted)
                .opacity(0.7)
            }
            row {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 16, height: 16)
                Text("Yab").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Symbol("chevron.down", size: 9.5, weight: .semibold)
                    .foregroundStyle(Palette.muted)
            }
            .foregroundStyle(Palette.ink)
            row {
                Text(ask.place.switchName).font(.system(size: 12))
                Spacer(minLength: 8)
                SwitchDrawing(on: ask.stage == .checking)
            }
            .foregroundStyle(Palette.ink)
            .padding(.leading, 24)
            .background(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
            )
            .padding(4)
        }
        .background(Palette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .animation(Motion.arrive, value: ask.stage)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 10)
            .frame(height: SideBar.row)
    }
}

/// A macOS switch, drawn: off, or on in the accent.
private struct SwitchDrawing: View {
    let on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Color.accentColor : Palette.faint)
            .frame(width: 26, height: 15)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 11, height: 11).padding(2)
            }
    }
}
