import SwiftUI

/// The Mac's downloads button (Hoard) for the iPad: in the sidebar's foot
/// always, in the toolbar while the sidebar is away and there is something
/// to show. Its popover holds the first file's question, then the list.
/// The phone keeps these in its plate (ChromeLayer), which the iPad's
/// toolbar layout never mounts.
struct TabletDownloadsButton: View {
    @Environment(AppModel.self) private var app
    /// Only the button on screen presents, so two never stand at once.
    let active: Bool
    let id: String
    @State private var open = false
    /// The popover is open because a question opened it.
    @State private var askOpened = false

    private var question: DownloadAsk? { app.downloads.asking(isPrivate: app.pageIsPrivate) }
    /// What the list holds, for VoiceOver: "2 files".
    private var kept: String {
        let count = app.downloads.list(isPrivate: app.pageIsPrivate).count
        return count == 0 ? "" : DownloadWords.files(count)
    }
    private var busy: Bool { question != nil || app.downloads.list(isPrivate: app.pageIsPrivate).contains(where: \.isRunning) }

    var body: some View {
        Button { open.toggle() } label: {
            Glyph(mac: .yabDownload, size: 17)
                .frame(width: Metrics.touch, height: Metrics.touch)
                .overlay(alignment: .topTrailing) {
                    if busy {
                        Circle().fill(Ink.unread)
                            .frame(width: Metrics.Tablet.downloadDot, height: Metrics.Tablet.downloadDot)
                            .offset(x: -Metrics.Tablet.downloadDotInset, y: Metrics.Tablet.downloadDotInset)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Downloads")
        .accessibilityValue(question != nil ? "Asking" : busy ? "Downloading" : kept)
        .accessibilityIdentifier(id)
        .popover(isPresented: Binding(get: { active && open }, set: { open = $0 }), arrowEdge: .bottom) {
            TabletDownloadsPanel().environment(app).presentationCompactAdaptation(.popover)
        }
        // A site's first file asks at once, from wherever the button is. A
        // popover the question opened goes with its answer, as the phone's
        // card does; one the person opened stays.
        .onChange(of: question?.id, initial: true) { old, id in
            if id != nil {
                ask()
            } else if old != nil, askOpened {
                askOpened = false
                open = false
            }
        }
        // Back on screen, a question still waiting opens it again, as its own.
        .onChange(of: active) { _, shown in if shown && question != nil { ask() } else { open = false } }
        .onChange(of: open) { _, shown in
            if shown { app.downloads.listOpened(isPrivate: app.pageIsPrivate) } else { askOpened = false }
        }
    }

    /// Opens the popover for the question: the question's, unless it was open already.
    private func ask() {
        if !open { askOpened = true }
        open = true
    }
}

/// The popover's body: the question while one waits, else every file.
struct TabletDownloadsPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let isPrivate = app.pageIsPrivate
        Group {
            if let question = app.downloads.asking(isPrivate: isPrivate) {
                DownloadAskCard(ask: question)
                    .id(question.id)
                    .frame(height: Metrics.DownloadAsk.height)
                    .padding(Metrics.Tablet.downloadsInset)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Downloads").font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, Metrics.PageMenu.inset + 6).padding(.vertical, 10)
                        DownloadsBody(ink: PageMenuInk(dark: isPrivate || scheme == .dark), host: nil, isPrivate: isPrivate)
                    }
                    .padding(.top, Metrics.Tablet.downloadsInset)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: Metrics.Tablet.downloadsHeight)
                // The list's own: around the question it would take the card's
                // name (download.ask), the one element the two make.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("tablet.downloads")
            }
        }
        .frame(width: Metrics.Tablet.downloadsWidth)
        .animation(Motion.downloadAsk.current, value: app.downloads.asking(isPrivate: isPrivate)?.id)
    }
}
