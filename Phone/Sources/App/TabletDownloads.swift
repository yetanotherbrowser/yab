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

    private typealias M = Metrics.Tablet
    private var isPrivate: Bool { app.pageIsPrivate }
    private var question: DownloadAsk? { app.downloads.asking(isPrivate: isPrivate) }
    private var running: [DownloadEntry] { app.downloads.list(isPrivate: isPrivate).filter(\.isRunning) }
    /// The last file in, as the Mac's button keeps its icon: until the list
    /// or the file opens, with no timer (the Mac's Hoard `waiting`).
    private var waiting: DownloadEntry? {
        guard let arrival = app.downloads.arrival, arrival.done, !arrival.seen,
              let file = app.downloads.entry(arrival.id), file.isPrivate == isPrivate else { return nil }
        return file
    }
    /// What the list holds, for VoiceOver: "2 files".
    private var kept: String {
        let count = app.downloads.list(isPrivate: isPrivate).count
        return count == 0 ? "" : DownloadWords.files(count)
    }

    var body: some View {
        let running = running
        Button { open.toggle() } label: {
            ZStack {
                if let waiting {
                    Glyph(mac: DownloadMark.of(waiting.name), size: M.downloadMark)
                        .transition(.scale(scale: Motion.downloadMarkScale).combined(with: .opacity))
                } else {
                    Glyph(mac: .yabDownload, size: M.downloadIdleMark)
                }
                if !running.isEmpty { ring(DownloadWords.overall(running)) }
            }
            .frame(width: M.downloadsDoor, height: M.downloadsDoor)
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
                Motion.downloadBump.keyframes(reduced: Motion.reduced)
            }
            .animation(Motion.downloadAsk.current, value: waiting?.id)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Downloads")
        .accessibilityValue(question != nil ? "Asking" : !running.isEmpty ? "Downloading" : waiting.map { "Downloaded \($0.name)" } ?? kept)
        .accessibilityIdentifier(id)
        .modifier(TabletDownloadsHost(active: active, id: id, open: $open))
    }

    /// The Mac's badge: the progress round the mark, a track where it
    /// doesn't know the size yet.
    private func ring(_ percent: Int?) -> some View {
        ZStack {
            Circle().stroke(Ink.primary.opacity(M.downloadRingTrack), lineWidth: M.downloadRingLine)
            Circle().trim(from: 0, to: CGFloat(percent ?? 0) / 100)
                .stroke(Ink.primary, style: StrokeStyle(lineWidth: M.downloadRingLine, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: M.downloadRing, height: M.downloadRing)
        .accessibilityHidden(true)
    }
}

/// What makes a control the downloads' place: the list's popover, the
/// first file's question at once, and where a thrown file lands. The
/// button wears it, and so does the band's folded + menu in a narrow pane.
struct TabletDownloadsHost: ViewModifier {
    @Environment(AppModel.self) private var app
    /// Only the control on screen presents, so two never stand at once.
    let active: Bool
    let id: String
    @Binding var open: Bool
    /// The popover is open because a question opened it.
    @State private var askOpened = false
    @State private var frame = CGRect.zero

    private var question: DownloadAsk? { app.downloads.asking(isPrivate: app.pageIsPrivate) }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0; land() }
            .onChange(of: active, initial: true) { _, _ in land() }
            .onDisappear { publish(nil); app.downloads.showsList(id, isPrivate: nil) }
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
            .onChange(of: open) { _, shown in if !shown { askOpened = false } }
            // The list on screen: a file that ends in it was watched. A
            // question stands in the popover in its place, and one that
            // opened the popover closes it with its answer.
            .onChange(of: listShown ? app.pageIsPrivate : nil) { _, isPrivate in app.downloads.showsList(id, isPrivate: isPrivate) }
            .onChange(of: app.workspace.downloadsShown) { _, _ in if active { open = true } }
    }

    private var listShown: Bool { active && open && question == nil && !askOpened }

    /// Opens the popover for the question: the question's, unless it was open already.
    private func ask() {
        if !open { askOpened = true }
        open = true
    }

    /// A file in the air lands on the control on screen.
    private func land() { publish(active && !frame.isEmpty ? frame : nil) }

    /// Written only when it moves: a flight on its way watches it.
    private func publish(_ landing: CGRect?) {
        if app.workspace.downloadsLandings[id] != landing { app.workspace.downloadsLandings[id] = landing }
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
            .scaleEffect(lifted ? 1 : Motion.DownloadFlight.liftScale)
            .opacity(lifted ? 1 : 0)
            .modifier(TabletFlightPose(start: rise, end: landing ?? rise, travel: travel,
                                       landingScale: M.downloadRing / M.downloadDisc, fadesWhereItRose: landing == nil))
            .offset(y: lifted ? 0 : M.downloadRise)
            .onAppear(perform: fly)
            // A held flight (a test state) stands still on its arc, aimed at
            // the button as soon as the button has a place on screen.
            .onChange(of: target, initial: true) { _, target in
                if flight.held != nil, landing == nil { landing = target }
            }
    }

    /// The middle of the downloads control on screen, where a file lands.
    private var target: CGPoint? {
        app.workspace.downloadsLandings.values.first.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    private func fly() {
        let id = flight.id, downloads = app.downloads
        if let held = flight.held { hold(at: held); return }
        guard !Motion.disabled, !Motion.reduced else { downloads.landed(id); return }
        withAnimation(Motion.downloadLift.animation) { lifted = true } completion: {
            // Where it lands is asked once it has lifted off.
            landing = target
            withAnimation(Motion.downloadArc.animation) { travel = 1 } completion: {
                downloads.landed(id)
            }
        }
    }

    private func hold(at held: CGFloat) {
        lifted = true
        travel = held
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

    private typealias M = Metrics.Tablet

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
        let shrinkFrom = Motion.DownloadFlight.shrinkFrom, fadeFrom = Motion.DownloadFlight.fadeFrom
        let shrink = t < shrinkFrom ? 1 : 1 + (landingScale - 1) * (t - shrinkFrom) / (1 - shrinkFrom)
        let fade: CGFloat = fadesWhereItRose ? 1 - t : (t < fadeFrom ? 1 : 1 - (t - fadeFrom) / (1 - fadeFrom))
        return content
            .scaleEffect(shrink)
            .opacity(Double(max(0, fade)))
            .position(x: x, y: y)
    }

    static func control(from start: CGPoint, to end: CGPoint) -> CGPoint {
        end.y < start.y - M.downloadHighButton
            ? CGPoint(x: start.x + (end.x - start.x) * M.downloadHighAlong, y: start.y - M.downloadHighRise)
            : CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - M.downloadArcHeight)
    }
}

/// The Mac's thrown file: near black, a white arrow, a teal glow.
private struct TabletDownloadDisc: View {
    private typealias M = Metrics.Tablet
    private typealias Arrow = Metrics.Tablet.DownloadArrow

    var body: some View {
        let side = M.downloadDisc
        let k = side / Arrow.grid
        let at = { (point: CGPoint) in CGPoint(x: point.x * k, y: point.y * k) }
        Circle()
            .fill(Ink.downloadDiscFill)
            .overlay {
                Path { path in
                    path.move(to: at(Arrow.shaftTop))
                    path.addLine(to: at(Arrow.shaftBottom))
                    path.move(to: at(Arrow.headLeft))
                    path.addLine(to: at(Arrow.headTip))
                    path.addLine(to: at(Arrow.headRight))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: Arrow.line * k, lineCap: .round, lineJoin: .round))
            }
            .frame(width: side, height: side)
            .shadow(color: Ink.downloadDiscGlow.opacity(M.downloadDiscGlowOpacity), radius: M.downloadDiscGlowRadius)
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
                        Text("Downloads").font(.system(size: Metrics.Tablet.downloadsTitleFont, weight: .semibold))
                            .padding(.horizontal, Metrics.PageMenu.inset + Metrics.Tablet.downloadsTitleInset)
                            .padding(.vertical, Metrics.Tablet.downloadsTitleVertical)
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
