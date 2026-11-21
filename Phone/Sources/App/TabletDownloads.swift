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
    @State private var frame = CGRect.zero

    private typealias M = Metrics.Tablet
    private var isPrivate: Bool { app.pageIsPrivate }
    private var question: DownloadAsk? { app.downloads.asking(isPrivate: isPrivate) }
    private var running: [DownloadEntry] { app.downloads.list(isPrivate: isPrivate).filter(\.isRunning) }
    /// The last file in, as the Mac's button keeps its icon: until the list
    /// or the file opens.
    private var waiting: DownloadEntry? {
        app.downloads.waiting.flatMap(app.downloads.entry).flatMap { $0.isPrivate == isPrivate && $0.isDone ? $0 : nil }
    }

    var body: some View {
        let running = running
        Button { open.toggle() } label: {
            ZStack {
                if let waiting {
                    Glyph(mac: DownloadMark.of(waiting.name), size: 19)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    Glyph(mac: .yabDownload, size: 17)
                }
                if !running.isEmpty { ring(DownloadWords.overall(running)) }
            }
            .frame(width: Metrics.touch, height: Metrics.touch)
            .overlay(alignment: .topTrailing) {
                if question != nil {
                    Circle().fill(Ink.unread)
                        .frame(width: M.downloadDot, height: M.downloadDot)
                        .offset(x: -M.downloadDotInset, y: M.downloadDotInset)
                }
            }
            // Each arrival, the button gives a little, as the Mac's does.
            .keyframeAnimator(initialValue: CGFloat(1), trigger: app.downloads.bumps) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(Motion.reduced ? 1 : M.downloadBump, duration: 0.1)
                SpringKeyframe(1, duration: 0.3)
            }
            .animation(Motion.downloadAsk.current, value: waiting?.id)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0; land() }
        .onChange(of: active, initial: true) { _, _ in land() }
        .onDisappear { app.workspace.downloadsLandings[id] = nil }
        .accessibilityLabel("Downloads")
        .accessibilityValue(question != nil ? "Asking" : !running.isEmpty ? "Downloading" : waiting.map { "Downloaded \($0.name)" } ?? "")
        .accessibilityIdentifier(id)
        .popover(isPresented: Binding(get: { active && open }, set: { open = $0 }), arrowEdge: .bottom) {
            TabletDownloadsPanel().environment(app).presentationCompactAdaptation(.popover)
        }
        // A site's first file asks at once, from wherever the button is.
        .onChange(of: question?.id, initial: true) { _, id in if id != nil { open = true } }
        .onChange(of: active) { _, shown in open = shown && question != nil }
        .onChange(of: open) { _, shown in if shown { app.downloads.seen() } }
    }

    /// A file in the air lands on the button on screen.
    private func land() { app.workspace.downloadsLandings[id] = active && !frame.isEmpty ? frame : nil }

    /// The Mac's badge: the progress round the mark, a track where it
    /// doesn't know the size yet.
    private func ring(_ percent: Int?) -> some View {
        ZStack {
            Circle().stroke(Ink.primary.opacity(0.15), lineWidth: M.downloadRingLine)
            Circle().trim(from: 0, to: CGFloat(percent ?? 0) / 100)
                .stroke(Ink.primary, style: StrokeStyle(lineWidth: M.downloadRingLine, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: M.downloadRing, height: M.downloadRing)
        .accessibilityHidden(true)
    }
}

/// Files thrown at the downloads button, as the Mac's are (HoardSkyView):
/// a dark disc with a white arrow lifts off where the link was held, then
/// flies an arc into the button, smaller as it comes in, and the button
/// gives. Over everything, touching nothing.
struct TabletDownloadFlights: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(app.downloads.flights) { flight in
                TabletDownloadFlight(flight: flight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { app.downloads.flies = true }
        .onDisappear { app.downloads.flies = false }
    }
}

private struct TabletDownloadFlight: View {
    @Environment(AppModel.self) private var app
    let flight: DownloadStore.Flight
    @State private var lifted = false
    @State private var travel: CGFloat = 0
    @State private var landing: CGPoint?

    private typealias M = Metrics.Tablet

    var body: some View {
        let rise = CGPoint(x: flight.from.x, y: flight.from.y - M.downloadRise)
        TabletDownloadDisc()
            .scaleEffect(lifted ? 1 : 0.4)
            .opacity(lifted ? 1 : 0)
            .modifier(TabletFlightPose(start: rise, end: landing ?? rise, travel: travel,
                                       landingScale: M.downloadRing / M.downloadDisc, fadesWhereItRose: landing == nil))
            .offset(y: lifted ? 0 : M.downloadRise)
            .onAppear(perform: fly)
    }

    private func fly() {
        let id = flight.id, downloads = app.downloads
        guard !Motion.disabled, !Motion.reduced else { downloads.landed(id); return }
        withAnimation(.easeOut(duration: M.downloadLift)) { lifted = true } completion: {
            // Where it lands is asked once it has lifted off.
            landing = app.workspace.downloadsLandings.values.first.map { CGPoint(x: $0.midX, y: $0.midY) }
            withAnimation(.timingCurve(0.45, 0, 0.2, 1, duration: M.downloadArc)) { travel = 1 } completion: {
                downloads.landed(id)
            }
        }
    }
}

/// Along the arc: down to a low button it rises first and falls in, up to
/// a high one it goes along and then up (the Mac's HoardSkyView.arc); down
/// to the badge's size past halfway, gone in its last moment.
private struct TabletFlightPose: ViewModifier, Animatable {
    let start: CGPoint
    let end: CGPoint
    var travel: CGFloat
    let landingScale: CGFloat
    let fadesWhereItRose: Bool

    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func body(content: Content) -> some View {
        let t = travel
        let control = Self.control(from: start, to: end)
        let u = 1 - t
        let x = u * u * start.x + 2 * u * t * control.x + t * t * end.x
        let y = u * u * start.y + 2 * u * t * control.y + t * t * end.y
        let shrink = t < 0.55 ? 1 : 1 + (landingScale - 1) * (t - 0.55) / 0.45
        let fade: CGFloat = fadesWhereItRose ? 1 - t : (t < 0.94 ? 1 : 1 - (t - 0.94) / 0.06)
        return content
            .scaleEffect(shrink)
            .opacity(Double(max(0, fade)))
            .position(x: x, y: y)
    }

    static func control(from start: CGPoint, to end: CGPoint) -> CGPoint {
        end.y < start.y - 40
            ? CGPoint(x: start.x + (end.x - start.x) * 0.7, y: start.y - 10)
            : CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - Metrics.Tablet.downloadArcHeight)
    }
}

/// The Mac's thrown file: near black, a white arrow, a teal glow.
private struct TabletDownloadDisc: View {
    var body: some View {
        let side = Metrics.Tablet.downloadDisc
        let k = side / 19
        Circle()
            .fill(Color(red: 13 / 255, green: 26 / 255, blue: 20 / 255))
            .overlay {
                Path { path in
                    path.move(to: CGPoint(x: 9.5 * k, y: 5 * k))
                    path.addLine(to: CGPoint(x: 9.5 * k, y: 13.4 * k))
                    path.move(to: CGPoint(x: 6 * k, y: 10.2 * k))
                    path.addLine(to: CGPoint(x: 9.5 * k, y: 13.6 * k))
                    path.addLine(to: CGPoint(x: 13 * k, y: 10.2 * k))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: 1.7 * k, lineCap: .round, lineJoin: .round))
            }
            .frame(width: side, height: side)
            .shadow(color: Color(red: 90 / 255, green: 190 / 255, blue: 170 / 255).opacity(0.55), radius: 5)
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
            }
        }
        .frame(width: Metrics.Tablet.downloadsWidth)
        .animation(Motion.downloadAsk.current, value: app.downloads.asking(isPrivate: isPrivate)?.id)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tablet.downloads")
    }
}
