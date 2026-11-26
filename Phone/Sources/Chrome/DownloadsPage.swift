import SwiftUI
import UIKit

/// The Downloads page, the page menu's sheet with another body: every file
/// from the menu and the Now line, one site's from Site Settings (one step
/// deeper, as the certificate is). A tap opens a file, a hold shares, shows or
/// deletes it; a file on its way can be stopped, one that failed tried again.
/// The rows are the menu's. Equatable, so the morph's frames leave it alone.
struct DownloadsBody: View, Equatable {
    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    let ink: PageMenuInk
    /// This site's files; nil every file.
    let host: String?
    let isPrivate: Bool
    private typealias M = Metrics.PageMenu
    private typealias S = Metrics.SiteSettingsPage

    nonisolated static func == (a: DownloadsBody, b: DownloadsBody) -> Bool {
        a.ink.dark == b.ink.dark && a.host == b.host && a.isPrivate == b.isPrivate
    }

    var body: some View {
        let files = app.downloads.list(isPrivate: isPrivate, host: host)
        let now = Date()
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                if files.isEmpty {
                    Text("No Downloads")
                        .font(.system(size: S.rowFont))
                        .foregroundStyle(ink.secondary)
                        .frame(maxWidth: .infinity, minHeight: M.listRow)
                        .accessibilityIdentifier("downloads.empty")
                }
                ForEach(Array(files.enumerated()), id: \.element.id) { i, file in
                    if i > 0 { Rectangle().fill(ink.hairline).frame(height: 1 / displayScale) }
                    DownloadRow(file: file, showsHost: host == nil, now: now, ink: ink)
                }
            }
            .background(ink.siteCard, in: RoundedRectangle(cornerRadius: S.cardRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: S.cardRadius, style: .continuous))
            .padding(.horizontal, M.inset)

            // The Yab folder in Files: a private file was never put there.
            if host == nil, !isPrivate, !files.isEmpty {
                Button { app.showDownloadsInFiles() } label: {
                    MenuRowLabel(glyph: .folder, title: "Show in Files", ink: ink)
                }
                .buttonStyle(PageMenuPress(ink: ink, radius: S.cardRadius))
                .background(ink.siteCard, in: RoundedRectangle(cornerRadius: S.cardRadius, style: .continuous))
                .padding(.horizontal, M.inset)
                .padding(.top, M.groupGap)
                .accessibilityIdentifier("downloads.showInFiles")
            }
        }
        .padding(.bottom, M.bottomPad)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloads.page")
    }
}

/// One file in the list.
private struct DownloadRow: View {
    @Environment(AppModel.self) private var app
    let file: DownloadEntry
    let showsHost: Bool
    let now: Date
    let ink: PageMenuInk
    private typealias M = Metrics.PageMenu

    var body: some View {
        let detail = DownloadWords.detail(file, showsHost: showsHost, now: now)
        let label = MenuRowLabel(glyph: DownloadMark.of(file.name), title: file.name, subtitle: detail, ink: ink, fileName: true)
        HStack(spacing: 0) {
            if file.isDone {
                Button { app.openDownload(file) } label: { label }
                    .buttonStyle(PageMenuPress(ink: ink, radius: 0))
                    .contextMenu {
                        Button { app.shareDownload(file) } label: { Label { Text("Share") } icon: { mark(.yabShare) } }
                        if !file.isPrivate {
                            Button { app.showDownloadInFiles(file) } label: { Label { Text("Show in Files") } icon: { mark(.folder) } }
                        }
                        Button(role: .destructive) { app.deleteDownload(file) } label: { Label { Text("Delete") } icon: { mark(.trash) } }
                    }
                    .accessibilityIdentifier("downloads.row.\(file.name)")
            } else {
                label
                    .accessibilityIdentifier("downloads.row.\(file.name)")
                if file.isRunning, app.downloads.canStop(file.id) {
                    word("Stop", id: "downloads.stop", color: ink.ink) { app.downloads.stop(file.id) }
                } else if file.state == .failed, app.downloads.canRetry(file.id) {
                    word("Retry", id: "downloads.retry", color: ink.ink) { app.retryDownload(file) }
                }
            }
        }
    }

    private func mark(_ glyph: MacGlyph) -> Image {
        UIImage.menuGlyph(glyph).map { Image(uiImage: $0) } ?? Image(systemName: "circle")
    }

    private func word(_ title: String, id: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: M.valueFont + 1, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 16)
                .frame(minHeight: M.listRow)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// The menu's row, beside Site Settings: only with something to show, what
/// goes on in words at its end. A view of its own so a percent redraws this
/// row and not the menu.
struct DownloadsMenuRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    let ink: PageMenuInk
    let isPrivate: Bool

    var body: some View {
        let files = app.downloads.list(isPrivate: isPrivate)
        if let value = DownloadWords.menuValue(files) {
            Rectangle().fill(ink.hairline).frame(height: 1 / displayScale)
            Button { app.openDownloadsPage() } label: {
                MenuRowLabel(glyph: .yabDownload, title: "Downloads", ink: ink, value: value)
            }
            .buttonStyle(PageMenuPress(ink: ink, radius: 0) { app.prepare(.downloads, $0) })
            .accessibilityIdentifier("plate.menu.downloads")
            .accessibilityValue(value)
        }
    }
}

/// A site's first file: a glass card in the Now line's place, over the plate,
/// with the page live under it. Download turns it into the line.
struct DownloadAskCard: View {
    @Environment(AppModel.self) private var app
    let ask: DownloadAsk
    private typealias A = Metrics.DownloadAsk

    /// Its foot where the Now line's is, as wide, and the plate left free.
    static func frame(in chrome: ChromeGeometry) -> CGRect {
        let now = chrome.now
        return CGRect(x: now.minX, y: now.maxY - A.height, width: now.width, height: A.height)
    }

    var body: some View {
        VStack(spacing: A.gap) {
            HStack(spacing: Metrics.Now.gap) {
                Glyph(mac: DownloadMark.of(ask.name), size: A.icon, color: Ink.primary)
                    .frame(width: Metrics.Now.iconBox, height: Metrics.Now.iconBox)
                VStack(alignment: .leading, spacing: Metrics.Now.lineGap) {
                    Text("Download \(ask.name)?")
                        .font(.system(size: Metrics.Now.titleFont, weight: .semibold))
                        .tracking(-0.01 * Metrics.Now.titleFont)
                        .foregroundStyle(Ink.primary)
                        .truncationMode(.middle)
                    Text(DownloadWords.askLine(ask))
                        .font(.system(size: Metrics.Now.subtitleFont))
                        .foregroundStyle(Ink.secondary)
                        .truncationMode(.tail)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: A.buttonGap) {
                choice("Cancel", id: "download.ask.cancel", ink: Ink.primary, fill: Ink.primary.opacity(0.08)) { app.answerDownload(ask, false) }
                choice("Download", id: "download.ask.download", ink: .white, fill: Ink.unread) { app.answerDownload(ask, true) }
            }
        }
        .padding(A.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassPlate(RoundedRectangle(cornerRadius: A.radius, style: .continuous), interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("download.ask")
    }

    private func choice(_ title: String, id: String, ink: Color, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Metrics.Now.actionFont + 1, weight: .semibold))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .frame(height: A.buttonHeight)
                .background(fill, in: RoundedRectangle(cornerRadius: A.radius - A.padding, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

extension Metrics {
    /// The first file's card: the Now line's font, 30 round, concentric to
    /// its buttons, as drawn.
    enum DownloadAsk {
        static let height: CGFloat = 124
        static let radius: CGFloat = 30
        static let padding: CGFloat = 14
        static let gap: CGFloat = 12
        static let icon: CGFloat = 22
        static let buttonHeight: CGFloat = 44
        static let buttonGap: CGFloat = 8
    }
}

extension Motion {
    /// The card turning into the Now line.
    static let downloadAsk = spring("downloadAsk", response: 0.32)
}

/// Going, the card closes down onto the line at its foot.
private struct AskClosing: ViewModifier, Animatable {
    var closed: CGFloat

    var animatableData: CGFloat {
        get { closed }
        set { closed = newValue }
    }

    func body(content: Content) -> some View {
        let height = Metrics.DownloadAsk.height + (Metrics.Now.height - Metrics.DownloadAsk.height) * closed
        content
            .frame(height: height)
            .opacity(Double(1 - closed))
    }
}

extension AnyTransition {
    static var downloadAsk: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: Metrics.Now.goneDrop)),
                    removal: .modifier(active: AskClosing(closed: 1), identity: AskClosing(closed: 0)))
    }
}
