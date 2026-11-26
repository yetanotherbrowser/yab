import SwiftUI
import AppKit
import Combine
import QuartzCore
import os
import UniformTypeIdentifiers

// Downloads under way, and the one button that says so.
//
// The button lives at the foot of the column, or with the tabs on top beside
// Updates at the far end of the strip or the address bar. In the column it
// is always there, before the first download too (asked back 2026-10-15);
// in the strip and the address bar it takes its place from the first
// download of a session to its end, as Arc's: before that it takes no room
// there, the doors beside it show only under the pointer (feedback 81, 126).
// Downloads of earlier sessions are in the box's Downloads (⇧⌘J). Where its
// place can't be seen (the column put away, a page that has the screen) it
// never rests over the page: the same button comes out at the bottom-left
// edge as a chip only while something is going, and goes home after
// (feedback 38).
//
// A download is rare, so it gets the one expressive beat in the app. A dark
// disc lifts off where it was clicked and flies an arc into the button, which
// stays as it is until it lands. Then the badge takes the
// button's place, in the space's own colors, with the progress round it. When
// everything is in, the circle goes back into the button and the file's own
// icon rises out of it and waits, with no timer, for the pointer. On the
// button the list opens, and the badge or the file rides into its own row
// (HoardCarrier).
//
// The window is one hosting view, and a SwiftUI animation, even a ring the
// size of a letter, has it work out the whole window again on every frame.
// So nothing here animates in SwiftUI while a download runs: the badge is an
// AppKit view of its own that hears the Gauge directly and steps ten times a
// second, and its pop, the flight and the ride are Core Animation that plays
// in the render server. The button hears of a download only when it starts,
// lands, fails or ends.

@MainActor
final class Hoard: ObservableObject {
    struct Fetch: Identifiable, Equatable {
        let id: ObjectIdentifier
        var name: String
        let from: String
        var failed = false
        /// Stopped by an extension (chrome.downloads.pause), with what WebKit
        /// kept to go on from. Listed as stopped, but not as a failure.
        var paused = false
        let started = Date()
    }

    /// How far one has got. Kept apart from `Fetch`, on the Meter.
    struct Step: Equatable {
        /// Nil while WebKit hasn't said how big it is.
        var fraction: Double?
        var got: Int64 = 0
        var total: Int64 = 0
    }

    /// The numbers, ten times a second. Only the open list watches `steps`;
    /// the badge listens to `whole` without going through SwiftUI at all.
    final class Meter: ObservableObject {
        @Published fileprivate(set) var steps: [ObjectIdentifier: Step] = [:]
    }

    /// Everything under way together, 0…1, nil when none of it knows its
    /// size, for the badge's ring, which listens to this and nothing else.
    final class Gauge: ObservableObject {
        @Published fileprivate(set) var whole: Double?
    }

    /// Where a button stands. Each has its own popover, since the column's
    /// can be past the edge while the chip is out.
    enum Place { case side, strip, chip }

    /// Under way or failed, newest first. A finished one leaves this for
    /// the Loot, which remembers it.
    @Published private(set) var fetches: [Fetch] = [] {
        didSet { refreshShown() }
    }
    /// The button has a place in the strip and the address bar from the
    /// first download, or file in the air, of the session on, and keeps it:
    /// a button that went once a download was over left nowhere to look for
    /// it. Before that it has none there. The column's foot always has it.
    @Published private(set) var shown = false
    /// The last file's name, while its icon waits by the button for the
    /// pointer. No timer: it goes when the list opens, or the next one comes.
    @Published private(set) var waiting: String?
    var landed: Bool { waiting != nil }
    /// The waiting file has had its moment on the chip: the chip goes back
    /// into its edge and takes the file with it; the file still waits by
    /// the button in the column (owner, 2026-11-01).
    @Published private(set) var settled = false
    /// The last one is on disk and the ring goes full, just before the icon.
    @Published private(set) var filling = false
    /// The badge has the button's place, unless the list is open (its row has it).
    var badged: Bool { filling || !fetches.isEmpty && (!going.isEmpty || unseen) }
    /// On its way to or from its row: the row's icon waits until it arrives.
    @Published private(set) var carrying = false
    /// Back from its row: the badge is there at once, with no pop.
    private(set) var returned = false
    /// A failure nobody has looked at yet.
    @Published private(set) var unseen = false
    /// The chip stays out a little after the tick, then goes home.
    @Published private(set) var staying = false {
        didSet { refreshShown() }
    }
    /// Which button's list is open.
    @Published var openAt: Place? {
        didSet {
            if openAt == nil {
                panel?.dismiss()
                stack?.dismiss()
                if oldValue != nil { rideBack() }
            }
            refreshShown()
        }
    }
    /// Counts arrivals; the button gives a little each time.
    @Published private(set) var bumps = 0
    /// Files in the air right now.
    @Published private(set) var airborne = 0 {
        didSet { refreshShown() }
    }

    let meter = Meter()
    let gauge = Gauge()

    /// A file's throw, as an extension's icon flies: the pop up off the
    /// page, then the arc into the button.
    static let lift: Double = 0.11
    static let arc: Double = 0.56
    /// How long the ring stays full before the icon.
    static let full: Double = 0.18
    /// From the tick until the chip goes back into its edge with the file.
    static let home: Double = 0.9
    /// The list's curve and time, which what rides into its row shares.
    static let ride: Double = 0.26
    static let rideCurve = (x1: 0.32, y1: 0.72, x2: 0.0, y2: 1.0)
    /// The file's spring, as a curve past its end and back.
    static let spring: Double = 0.36
    static let springCurve = (x1: 0.3, y1: 1.35, x2: 0.5, y2: 1.0)

    weak var browser: Browser?

    /// Once there is something to show, the button takes its place, and the
    /// slot opens before a file in the air lands in it.
    private func refreshShown() {
        guard !shown, !fetches.isEmpty || airborne > 0 || staying || openAt != nil else { return }
        withAnimation(Motion.arrive) { shown = true }
    }

    /// Where files are drawn in flight. See HoardSky.
    weak var sky: HoardSkyView?
    /// The home button can't be seen: the chip is where things land.
    var away = false
    /// Where the home button is, in SwiftUI's window space, as last laid out.
    var home: CGRect?
    /// Where the chip stands once it is out, in the same space.
    var chipAt: CGPoint = .zero
    /// Each button's frame, in the same space, for the list to open from.
    var frames: [Place: CGRect] = [:]
    /// Which button last said each place's frame. The strip's button moves
    /// between the tab row and the address bar, and the one going can leave
    /// after the one coming has said where it is: only the button whose
    /// frame it is takes it away.
    var framers: [Place: UUID] = [:]
    /// Individual mounted buttons in test runs, including duplicates at one
    /// place; populated by the actual button's layout observer.
    var buttonFrames: [UUID: (place: Place, frame: CGRect)] = [:]
    /// The list, in a panel of its own over the window. See Tray.
    private var panel: Tray?
    /// The column's: its cards over the column. See HoardStack.
    private var stack: HoardStack?
    /// Between the column's button and the rows' top, as it opened.
    private var stackRoom: CGFloat = 0
    /// Only the rows covered by the download stack fade away.
    @Published private(set) var stackHeight: CGFloat = 0
    /// The last open stack's extent, retained for the mask's return path.
    private(set) var stackExtent: CGFloat = 0

    private var downloads: [ObjectIdentifier: any PageDownload] = [:]
    private var arriving: [ObjectIdentifier: Fetch] = [:]
    private var resume: [ObjectIdentifier: Data] = [:]
    private var watches: [ObjectIdentifier: NSKeyValueObservation] = [:]
    /// Where each download was asked for, in window coordinates, kept from
    /// the click until its name is known, past a save panel, if there is one.
    private var origins: [ObjectIdentifier: CGPoint] = [:]
    private var canceled: Set<ObjectIdentifier> = []
    private var pausing: Set<ObjectIdentifier> = []
    private var press: (at: CGPoint, time: CFTimeInterval, right: Bool)?
    private var monitor: Any?
    private weak var window: NSWindow?
    private var beat: DispatchWorkItem?
    /// When the last file in the air lands.
    private var touchdown: CFTimeInterval = 0
    /// Steps heard since the Meter was last told, and whether telling it is
    /// already on its way.
    private var heard: [ObjectIdentifier: Step] = [:]
    private var telling = false

    /// Anything going on that the chip should be out for.
    var calling: Bool {
        airborne > 0 || staying || unseen || waiting != nil && !settled || openAt != nil || fetches.contains { !$0.failed }
    }

    var going: [Fetch] { fetches.filter { !$0.failed } }

    // MARK: - where a download was asked for

    /// Every press in the window is noted, so a download that starts just
    /// after one knows where it came from.
    func watch(_ window: NSWindow) {
        self.window = window
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window != nil, event.window === self.window {
                self.notePress(at: event.locationInWindow, right: event.type == .rightMouseDown)
            }
            return event
        }
    }

    func notePress(at point: CGPoint, right: Bool = false) {
        press = (point, CACurrentMediaTime(), right)
    }

    /// A download has begun. Where it was clicked is taken now, while the
    /// click is fresh: a link a moment ago, or a context menu a little
    /// longer ago. Anything older, a redirect, an extension, flies from
    /// nowhere, and the button only gives.
    func expect(_ download: any PageDownload) {
        // Own the transfer before its response arrives. DNS, TLS and HTTP
        // failures can precede the destination/name callback entirely.
        downloads[ObjectIdentifier(download)] = download
        guard let press else { return }
        let age = CACurrentMediaTime() - press.time
        if age < (press.right ? 5 : 1.5) {
            origins[ObjectIdentifier(download)] = press.at
        }
    }

    // MARK: - the life of a download

    /// Its name is known and it is on its way to disk.
    func begin(_ download: any PageDownload, name: String, from host: String) {
        let id = ObjectIdentifier(download)
        downloads[id] = download

        if !shown { withAnimation(Motion.arrive) { shown = true } }
        settleForNext()

        // WebKit reports every chunk it writes, thousands a second on a
        // fast line, on its own thread. One in every 50 ms per download
        // reaches the main thread, and the Meter hears them ten times a
        // second all together.
        watches[id] = Self.observeProgress(download.progress) { [weak self] step in
            DispatchQueue.main.async { self?.moved(id, step) }
        }

        let fetch = Fetch(id: id, name: name, from: host)
        arriving[id] = fetch
        let arrive = { [weak self] in
            guard let self else { return }
            let fetch = arriving.removeValue(forKey: id) ?? fetch
            // One tried again already has its row, where it was.
            if let i = fetches.firstIndex(where: { $0.id == id }) {
                if fetches[i].name != name { fetches[i].name = name }
            } else if downloads[id] != nil {
                fetches.insert(fetch, at: 0)
                tell()
            }
            // Taking turns with the puzzle beside it (Hop).
            Hop.take { [weak self] in self?.bumps += 1 }
        }
        if let from = origins.removeValue(forKey: id),
           let sky,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            airborne += 1
            touchdown = max(touchdown, CACurrentMediaTime() + Hoard.lift + Hoard.arc)
            // The row and the badge wait for the file to land in the button.
            sky.fly(from: from, name: name, to: { [weak self] in self?.landing }) { [weak self] in
                self?.airborne -= 1
                arrive()
            }
        } else {
            arrive()
        }
    }

    /// A download can already have received bytes before its destination
    /// callback returns. Seed the meter from that state as well as hearing
    /// future changes; an unknown size still has a useful byte count. The
    /// bytes are watched, not the fraction: a file sent without its length
    /// (a compressed stream, as Vercel Blob once sent our DMG) keeps its
    /// fraction at 0 to the end, and the row then never moved.
    static func observeProgress(_ progress: Progress, report: @escaping (Step) -> Void) -> NSKeyValueObservation {
        let gate = Gate()
        return progress.observe(\.completedUnitCount, options: [.initial, .new]) { progress, _ in
            guard gate.pass(done: progress.fractionCompleted >= 1) else { return }
            let total = progress.totalUnitCount
            report(Step(fraction: total > 0 ? progress.fractionCompleted : nil,
                        got: progress.completedUnitCount, total: total))
        }
    }

    /// A file yab wrote itself, a capture saved (Capture.swift): the button
    /// makes room as it would for a download, and the file is flown in by
    /// whoever wrote it, then lands here.
    func lifting() {
        settleForNext()
        airborne += 1
    }

    /// `name`: the file that came, whose icon stands on the button.
    func touched(_ name: String) {
        airborne = max(0, airborne - 1)
        Hop.take { [weak self] in self?.bumps += 1 }
        guard going.isEmpty else { return }
        tick(name)
    }

    /// Another is on its way: whatever stood on the button for the last goes.
    private func settleForNext() {
        if staying { staying = false }
        beat?.cancel()
        if waiting != nil { waiting = nil }
        if settled { settled = false }
        if filling { filling = false }
    }

    /// Asked where to save it and told nowhere.
    func drop(_ download: any PageDownload) {
        let id = ObjectIdentifier(download)
        origins.removeValue(forKey: id)
        // One tried again and then not saved after all: its row goes back
        // to saying so, rather than starting forever.
        if let i = fetches.firstIndex(where: { $0.id == id }) {
            fetches[i].failed = true
            tell()
        } else {
            forget(id)
        }
    }

    private func moved(_ id: ObjectIdentifier, _ step: Step) {
        guard downloads[id] != nil else { return }
        heard[id] = step
        guard !telling else { return }
        telling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.tell() }
    }

    /// The Meter is told what was heard, and the ring how far everything
    /// under way has got.
    private func tell() {
        telling = false
        if !heard.isEmpty {
            var steps = meter.steps
            steps.merge(heard) { _, new in new }
            heard = [:]
            steps = steps.filter { id, _ in downloads[id] != nil }
            meter.steps = steps
        }
        gaugeNow()
        toldDock()
    }

    /// The ring: everything under way and in the air. Before anything has
    /// been heard it stands at its start, not spinning; it spins only for a
    /// file that is coming and hasn't said how big it is.
    private func gaugeNow() {
        // Going full before the icon: a step still on its way doesn't undo it.
        guard !filling else { return }
        let live = going.map(\.id) + arriving.values.filter { !$0.failed }.map(\.id)
        let steps = live.compactMap { meter.steps[$0] }
        let known = steps.compactMap(\.fraction)
        // To the half percent: a smaller step wouldn't show on the ring.
        let whole: Double? = known.isEmpty
            ? (steps.contains { $0.got > 0 } ? nil : 0)
            : (known.reduce(0, +) / Double(known.count) * 200).rounded() / 200
        if gauge.whole != whole { gauge.whole = whole }
    }

    /// The Dock's bar (DockProgress), told this window's bytes under way.
    private func toldDock() {
        DockProgress.shared.report(ObjectIdentifier(self), going.map { fetch in
            let step = meter.steps[fetch.id]
            return DockProgress.Bytes(got: step?.got ?? 0, total: step?.total ?? 0)
        })
    }

    /// A window closed with downloads going: they leave the Dock's bar.
    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        DockProgress.shared.report(ObjectIdentifier(self), [])
    }

    func finish(_ download: any PageDownload) {
        let id = ObjectIdentifier(download)
        let name = fetches.first { $0.id == id }?.name ?? arriving[id]?.name
        forget(id)
        fetches.removeAll { $0.id == id }
        tell()
        guard going.isEmpty else { return }
        land(name ?? "")
    }

    /// The last one is in: the ring full, if it was showing, then the file's
    /// own icon. A small file can be on disk before it has landed in the
    /// button: the icon waits for it.
    private func land(_ name: String) {
        staying = true
        beat?.cancel()
        let air = touchdown - CACurrentMediaTime()
        // In the air it never had a badge; with the list open the row's ring
        // goes as the file grows in its place.
        if air <= 0, openAt == nil {
            filling = true
            gauge.whole = 1
        }
        if openAt != nil { carrier(fading: true) }
        let work = DispatchWorkItem { [weak self] in self?.tick(name) }
        beat = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(openAt == nil ? Hoard.full : 0, air), execute: work)
    }

    private func tick(_ name: String) {
        filling = false
        guard going.isEmpty else { return }
        staying = true
        guard openAt == nil else {
            goHome()
            return
        }
        waiting = name
        settled = false
        // The file rises on the chip, then the chip goes home with it.
        DispatchQueue.main.asyncAfter(deadline: .now() + Hoard.home) { [weak self] in
            guard let self, waiting == name, going.isEmpty else { return }
            settled = true
            staying = false
        }
    }

    /// The chip goes home a little after what kept it out.
    private func goHome() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, !landed, going.isEmpty else { return }
            staying = false
        }
    }

    func fail(_ download: any PageDownload, resumeData: Data?) {
        let id = ObjectIdentifier(download)
        watches[id] = nil
        origins[id] = nil
        guard !canceled.contains(id) else {
            canceled.remove(id)
            downloads[id] = nil
            // Heard after the cancel's own answer, or instead of it: the
            // piece goes whichever comes first (`stopAndDiscard`).
            browser?.discardPart(of: id)
            return
        }
        if pausing.contains(id) || fetches.contains(where: { $0.id == id && $0.paused }) {
            if let resumeData { resume[id] = resumeData }
            return
        }
        if let i = fetches.firstIndex(where: { $0.id == id }) {
            fetches[i].failed = true
        } else if arriving[id] != nil {
            // A fast failure can beat the flight into the button. Keep its
            // row and retry data until it lands, just as a running file's.
            arriving[id]?.failed = true
        } else if downloads[id] != nil {
            let url = download.originalRequest?.url
            var fetch = Fetch(id: id, name: DownloadRequest.filename(browser?.downloadNames[id] ?? url?.lastPathComponent ?? ""),
                              from: url?.host() ?? "")
            fetch.failed = true
            fetches.insert(fetch, at: 0)
        } else {
            return
        }
        resume[id] = resumeData
        unseen = true
        tell()
    }

    // MARK: - from the list

    func cancel(_ fetch: Fetch) {
        let download = downloads[fetch.id]
        forget(fetch.id)
        fetches.removeAll { $0.id == fetch.id }
        tell()
        guard let download else { browser?.discardPart(of: fetch.id); return }
        stopAndDiscard(download)
    }

    /// Stopped for good: what it wrote goes with it (row 1005). WebKit
    /// keeps the piece under the file's own name, for resume data nobody
    /// will use now, and it sat in Downloads opening as a broken file.
    /// Removed once WebKit has let go of it, in its answer to the cancel
    /// or in `fail`, whichever is first; removing it is said once.
    private func stopAndDiscard(_ download: any PageDownload) {
        let id = ObjectIdentifier(download)
        canceled.insert(id)
        browser?.downloading.removeAll { $0 === download }
        // Invalidate a pending folder/consent reply and a publication task
        // now, even when the engine has already sent its final callback.
        browser?.download(download, didFailWithError: URLError(.cancelled), resumeData: nil)
        download.cancelDownload { [weak self] _ in
            DispatchQueue.main.async {
                self?.canceled.remove(id)
                self?.browser?.discardPart(of: id)
            }
        }
    }

    /// Stopped where it is by an extension, keeping what WebKit needs to
    /// go on; true when it kept enough. The row stays, saying Paused.
    func pause(_ download: any PageDownload) async -> Bool {
        let id = ObjectIdentifier(download)
        pausing.insert(id)
        defer { pausing.remove(id) }
        browser?.downloading.removeAll { $0 === download }
        let data = await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            download.cancelDownload { done.resume(returning: $0) }
        }
        watches[id] = nil
        browser?.downloadParts[id]?.partial?.stop()
        if let data { resume[id] = data }
        if let i = fetches.firstIndex(where: { $0.id == id }) {
            fetches[i].failed = true
            fetches[i].paused = true
        } else if arriving[id] != nil {
            arriving[id]?.failed = true
            arriving[id]?.paused = true
        }
        tell()
        return resume[id] != nil
    }

    /// An extension's resume, of a pause or a failure: as Try Again.
    func resume(_ id: ObjectIdentifier) -> Bool {
        guard let fetch = fetches.first(where: { $0.id == id }), fetch.failed,
              resume[id] != nil || downloads[id]?.originalRequest != nil else { return false }
        retry(fetch)
        return true
    }

    /// An extension's cancel: under way, as Stop; paused or failed, the
    /// row and its piece of a file go.
    func stop(_ id: ObjectIdentifier) {
        guard let fetch = fetches.first(where: { $0.id == id }) else {
            if let download = downloads[id] { forget(id); stopAndDiscard(download) }
            return
        }
        fetch.failed ? dismiss(fetch) : cancel(fetch)
    }

    /// From where it stopped when WebKit kept enough to go on, from the top
    /// otherwise, in the page that asked for it, or the tab in front once
    /// that page has gone.
    ///
    /// The row stays where it is and goes on at once: WebKit can take a
    /// while to hand the new download over, and a row that went on the
    /// click looked like a click that did nothing.
    func retry(_ fetch: Fetch) {
        let download = downloads[fetch.id]
        let data = resume[fetch.id]
        let request = download?.originalRequest
        // A pre-response row has only a display placeholder from the URL.
        // Keep an explicit or already chosen name, but let the next real
        // response supply its filename when none was ever received.
        let retryName = browser?.downloadNames[fetch.id] ?? browser?.downloadFiles[fetch.id]?.lastPathComponent
        guard data != nil || request != nil,
              let download, download.sourceView != nil || browser?.active?.builtPage != nil,
              let i = fetches.firstIndex(where: { $0.id == fetch.id }) else { return }
        fetches[i].failed = false
        fetches[i].paused = false
        if !fetches.contains(where: \.failed) { unseen = false }
        tell()
        let took: @MainActor ((any PageDownload)?) -> Void = { [weak self] new in
            guard let self else { return }
            guard let new else {
                if let i = fetches.firstIndex(where: { $0.id == fetch.id }) { fetches[i].failed = true }
                tell()
                return
            }
            // Said before it is kept, so an extension sees the same
            // download go on rather than a new one start.
            browser?.resumed(new, from: fetch.id)
            if data == nil, let retryName { browser?.downloadNames[ObjectIdentifier(new)] = retryName }
            browser?.keep(new)
            guard takeOver(fetch, by: new), data != nil else { return }
            // Resumed, it goes on writing the file it had begun and is
            // never asked where, so it is begun here.
            begin(new, name: fetch.name, from: fetch.from)
        }
        // From the top: the piece it left goes, and the file keeps its
        // name rather than coming back as "name 2".
        if data == nil { browser?.discardPart(of: fetch.id, keepingDestination: true) }
        download.restartDownload(from: data, fallback: browser?.active?.builtPage, done: took)
    }

    /// The row tried again becomes the new download's. False, and the new
    /// one stopped, when the row was taken away while it was on its way.
    private func takeOver(_ old: Fetch, by download: any PageDownload) -> Bool {
        let id = ObjectIdentifier(download)
        guard let i = fetches.firstIndex(where: { $0.id == old.id }) else {
            // Resumed, it was writing the file the dismissed row left.
            stopAndDiscard(download)
            return false
        }
        if let previous = downloads[old.id] { DownloadDestinations.transfer(from: previous.downloadID, to: download.downloadID) }
        forget(old.id)
        downloads[id] = download
        fetches[i] = Fetch(id: id, name: old.name, from: old.from)
        tell()
        return true
    }

    func dismiss(_ fetch: Fetch) {
        if fetch.failed { browser?.discardPart(of: fetch.id) }
        forget(fetch.id)
        fetches.removeAll { $0.id == fetch.id }
        if !fetches.contains(where: \.failed) { unseen = false }
    }

    func opened(at place: Place) {
        openAt = place
    }

    /// The button pressed: its list opens, or closes if it was open. The
    /// column's is for all of them: its cards come with the pointer. A
    /// failure's red is held until now; this press only takes it away.
    func press(_ place: Place) {
        if unseen, going.isEmpty {
            unseen = false
            return
        }
        place == .side ? allDownloads() : toggle(place)
    }

    /// A button's list or cards up, or down if they were.
    func toggle(_ place: Place) {
        if openAt == place {
            openAt = nil
            return
        }
        present(place, held: place == .side)
    }

    /// Every download, the downloads place, ⇧⌘J's.
    func allDownloads() {
        openAt = nil
        browser?.openPlace(.downloads)
    }

    private var rising: DispatchWorkItem?

    /// The pointer on the column's button, or off it: resting there a
    /// moment brings the cards up (HoardStack), which then go by
    /// themselves once it has left them and the button.
    func hover(_ place: Place, _ inside: Bool) {
        guard place == .side else {
            rising?.cancel()
            rising = nil
            guard inside, openAt != place, anything else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, openAt != place, anything else { return }
                present(place, hovered: true)
            }
            rising = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            return
        }
        rising?.cancel()
        rising = nil
        // The column is carried past the edge by its layer, so its foot's
        // native tracking can still report a hover where it stood. Only
        // the edge should answer while it is put away, not a files stack.
        guard inside, openAt != .side, browser?.column?.shown == true else { return }
        // While departing, the panel still covers the original button.
        // Its proxy forwards reentry here so the current motion reverses.
        if stack?.isVisible == true {
            present(.side)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            // Nothing downloaded: no stack, the tip says what a click does.
            // The column may also have gone away during the dwell.
            guard let self, openAt != .side, anything, browser?.column?.shown == true else { return }
            present(.side)
        }
        rising = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    /// Something going, or kept, for the column's stack to show.
    var anything: Bool { !fetches.isEmpty || !(browser?.loot.kept.isEmpty ?? true) }

    /// The column's cards risen, for the bench: up, not only on screen.
    var stackOut: Bool { stack?.phase.out ?? false }

    /// The column's cards up or down for the bench, up until it says.
    func holdStack(_ on: Bool) {
        if on, openAt != .side {
            present(.side, held: true)
        } else if !on, openAt == .side {
            openAt = nil
        }
    }

    private func present(_ place: Place, held: Bool = false, hovered: Bool = false, only: String? = nil) {
        guard let window, let browser, let frame = frames[place] else { return }
        if openAt != nil { openAt = nil }
        if #available(macOS 15.4, *) { ExtensionPanel.shared.close() }
        rides = only == nil && (badged || waiting != nil)
        if rides, place != .side { carrying = true }
        opened(at: place)
        let height = window.contentView?.bounds.height ?? window.frame.height
        let inWindow = CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
        if place == .side {
            stand(over: window, from: inWindow, browser: browser, held: held, only: only)
            return
        }
        let panel = panel ?? Tray(content: HoardList(hoard: self, loot: browser.loot, browser: browser), corner: HoardList.corner)
        self.panel = panel
        // Up from the foot of the column, down from the strip.
        let up = place == .side || place == .chip
        panel.present(over: window, from: window.convertToScreen(inWindow), up: up, growing: true, hovered: hovered) { [weak self] in
            guard let self, openAt == place else { return }
            openAt = nil
        }
        ride(from: place, in: window)
    }

    // MARK: - into its row

    /// What stands by the button rides into the row, as the list opens.
    private var rides = false
    private var rodeFrom: Place?
    private var carrierPanel: HoardCarrier?
    /// The row that gets it: the column's lowest, the list's first. Where
    /// its icon stands, in its panel, top down, and which panel.
    var rowSpot: (panel: () -> NSWindow?, icon: CGRect)? {
        didSet {
            DispatchQueue.main.async { [weak self] in self?.stack?.rowsMounted() }
        }
    }

    func picture(named name: String, done: @escaping (NSImage) -> Void) {
        guard let keep = browser?.loot.kept.first(where: { $0.name == name }) else { return }
        HoardPictures.shared.image(keep.url, done: done)
    }

    private var carrierArt: HoardCarrier.Art {
        if let waiting {
            return .file(waiting, browser?.loot.kept.first(where: { $0.name == waiting })?.url)
        }
        return .dial(HoardDialInks(tone: browser?.chorus.tone, look: window?.effectiveAppearance),
                     gauge.whole, going.isEmpty && unseen)
    }

    private func spotOnScreen() -> (CGPoint, CGFloat)? {
        guard let spot = rowSpot, let panel = spot.panel(), let content = panel.contentView else { return nil }
        let inPanel = NSPoint(x: spot.icon.midX, y: content.bounds.height - spot.icon.midY)
        return (panel.convertPoint(toScreen: inPanel), spot.icon.width)
    }

    /// Where it stands by the button, on screen, and how big.
    private func besideButton(_ place: Place, in window: NSWindow) -> (CGPoint, CGFloat)? {
        guard let frame = frames[place] else { return nil }
        let height = window.contentView?.bounds.height ?? window.frame.height
        var spot = CGPoint(x: frame.midX, y: height - frame.midY)
        var side = HoardDial.side
        if waiting != nil {
            let at = HoardBadgeView.fileAt(top: place == .strip)
            spot.x += at.width
            spot.y -= at.height
            side = HoardBadgeView.icon * (place == .strip ? HoardBadgeView.topScale : 1)
        }
        return (window.convertPoint(toScreen: spot), side)
    }

    private func ride(from place: Place, in window: NSWindow) {
        guard rides else { return }
        rides = false
        carrying = true
        rodeFrom = place
        let art = carrierArt
        let start = besideButton(place, in: window)
        let wasWaiting = waiting != nil
        // A pass of the run loop: the panel's rows have said where they stand.
        DispatchQueue.main.async { [weak self] in
            guard let self, carrying, openAt == place else { self?.carrying = false; return }
            if wasWaiting {
                waiting = nil
                goHome()
            }
            guard let start, let end = spotOnScreen(), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                carrying = false
                return
            }
            let target = wasWaiting ? end.1 : Self.dialSide(rowIcon: end.1)
            carrierNow(over: window).fly(art, from: start.0, side: start.1, to: end.0, side: target) { [weak self] in
                self?.carrying = false
            }
        }
    }

    /// The ring in a row: a row's picture is larger than its ring.
    static func dialSide(rowIcon: CGFloat) -> CGFloat { rowIcon > 30 ? 28 : rowIcon }

    private func carrierNow(over window: NSWindow) -> HoardCarrier {
        let carrier = carrierPanel ?? HoardCarrier()
        carrierPanel = carrier
        carrier.look(over: window)
        return carrier
    }

    /// The column carried away, put away or the card let go, with its cards
    /// up: they go with it, on its curve and as far (Peek.slide), and no
    /// chip comes out for a list that is no longer there.
    func columnWent() {
        guard openAt == .side, let browser, let stack else { return }
        let distance = -(browser.prefs.sideWidth + Metrics.floatInset + 40) * browser.flank.sign
        let slide: CABasicAnimation
        if !browser.folding, browser.sideCard {
            slide = CardMotion.leaving()
        } else {
            let pace: Reshape.Pace = browser.folding ? Reshape.pace : .depart
            slide = CABasicAnimation()
            slide.duration = pace.duration
            slide.timingFunction = pace.timing
        }
        rodeFrom = nil
        stack.leave(by: distance, slide)
        if openAt != nil { openAt = nil }
    }

    /// The list closed with a download running: back from its row to the button.
    private func rideBack() {
        guard badged, !away, let window, let place = rodeFrom, let end = besideButton(place, in: window) else { return }
        rodeFrom = nil
        guard let start = spotOnScreen(), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        carrying = true
        carrierNow(over: window).fly(carrierArt, from: start.0, side: Self.dialSide(rowIcon: start.1), to: end.0, side: end.1) { [weak self] in
            guard let self else { return }
            returned = true
            carrying = false
            DispatchQueue.main.async { [weak self] in self?.returned = false }
        }
    }

    /// The last one in with the list open: the row's ring shrinks and fades.
    private func carrier(fading: Bool) {
        guard let window, let end = spotOnScreen() else { return }
        let side = Self.dialSide(rowIcon: end.1)
        carrierNow(over: window).fly(.dial(HoardDialInks(tone: browser?.chorus.tone, look: window.effectiveAppearance), 1, false),
                                     from: end.0, side: side, to: end.0, side: side * 0.45, fading: true) {}
    }

    /// The column's button: the cards come up out of it, in the column's
    /// width, as many as stand between it and the pins.
    private func stand(over window: NSWindow, from button: CGRect, browser: Browser, held: Bool, only: String? = nil) {
        let height = window.contentView?.bounds.height ?? window.frame.height
        // Where the rows are in the window now, not where they last said:
        // put away and brought out over the page, the column had said so
        // from past the edge (x -263), and the cards came up there, off the
        // window's left edge, over the desktop, the rows hushed under where
        // they should have stood (2026-10-13). On the right the clip came
        // in the column's own space, the cards at the window's left edge
        // (a tester's picture, 2026-10-12).
        let pages = ColumnPages.of(browser)
        pages?.moved()
        var rows = (pages?.window === window ? pages?.rowsInWindow : nil) ?? browser.rowsClip ?? .zero
        if rows.width > 0, !(rows.minX...rows.maxX).contains(button.midX) {
            // Still not where the button is: the column it stands in.
            let content = window.contentView?.bounds.width ?? window.frame.width
            let inset = browser.prefs.sideShut ? Metrics.floatInset : 0
            let width = browser.prefs.sideShut ? browser.prefs.sideWidth : browser.sideShown
            rows.origin.x = browser.flank == .right ? content - inset - width : inset
            rows.size.width = width
        }
        // Up to the rows' top, the column's own when there are none.
        let top = rows.width > 0 && rows.height > 0 ? rows.minY : Metrics.strip
        stackRoom = height - button.maxY - top
        let left = rows.width > 0 ? rows.minX + SideBar.margin : button.minX
        let width = rows.width > 0 ? rows.width - 2 * SideBar.margin : browser.prefs.sideWidth - 2 * SideBar.margin
        let stack = stack ?? HoardStack(hoard: self, loot: browser.loot, browser: browser, fits: { [weak self] in
            let room = (self?.stackRoom ?? 0) - HoardStack.gap
            return Int(room / (HoardStack.card + HoardStack.between))
        }, heightChanged: { [weak self] height in
            guard let self, stackHeight != height else { return }
            if height > 0 { stackExtent = height }
            stackHeight = height
        })
        self.stack = stack
        stack.phase.riding = rides
        stack.floating = { [weak browser] in browser?.sidePeek == true }
        let screenButton = window.convertToScreen(button)
        let leftOnScreen = window.convertToScreen(NSRect(x: left, y: 0, width: 1, height: 1)).minX
        stack.present(over: window, from: screenButton, left: leftOnScreen, width: width, held: held, only: only, ready: { [weak self, weak window] in
            guard let self, let window, openAt == .side else { return }
            ride(from: .side, in: window)
        }) { [weak self] in
            guard let self, openAt == .side else { return }
            openAt = nil
        }
    }

    /// Tidy Downloads (DownloadNames): the file's row comes up out of the
    /// button by itself, alone, its name goes to dust and the new one comes
    /// in behind it (Rename.swift), and after a moment it goes down again,
    /// unless the pointer is on it. With the column out of sight, or the
    /// stack or a list already up, the file is only renamed.
    func peek(rename keep: Keep, to name: String) {
        guard let browser, browser.prefs.tidyDownloads,
              browser.loot.kept.contains(keep), keep.stillThere else { return }
        Rename.warm()
        guard openAt == nil, frames[.side] != nil, browser.column?.shown == true else {
            rename(keep, to: name, in: browser)
            return
        }
        let expected = DownloadNames.signature(keep.url)
        present(.side, held: true, only: keep.path)
        guard let stack, stack.isVisible else {
            rename(keep, to: name, in: browser)
            return
        }
        // Wait for the stack's own spring and title geometry, then change
        // its file. The timer belongs to this presentation alone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self, weak stack] in
            guard let self, let stack, let browser = self.browser, stack.phase.only == keep.path else { return }
            guard browser.prefs.tidyDownloads, browser.loot.kept.contains(keep),
                  expected != nil, DownloadNames.signature(keep.url) == expected else { stack.release(); return }
            let dusted = stack.dustName()
            guard let moved = rename(keep, to: name, in: browser, animate: dusted) else {
                stack.release()
                return
            }
            stack.phase.only = moved.path
            DispatchQueue.main.asyncAfter(deadline: .now() + Rename.cross + 2.4) { [weak stack] in
                guard let stack, stack.phase.only == moved.path else { return }
                stack.release()
            }
        }
    }

    private var renameSteps: [String: UUID] = [:]

    /// The row's Undo and ⌘Z consume the same step, once.
    func undoName(_ keep: Keep) {
        guard let browser else { return }
        if let step = renameSteps.removeValue(forKey: keep.path) {
            browser.undo(step: step)
        } else {
            browser.loot.undoRename(keep)
        }
    }

    @discardableResult
    private func rename(_ keep: Keep, to name: String, in browser: Browser, animate: Bool = false) -> Keep? {
        guard let moved = browser.loot.rename(keep, to: name, animate: animate) else { return nil }
        let step = browser.did { [weak self, weak loot = browser.loot] in
            loot?.undoRename(moved)
            self?.renameSteps[moved.path] = nil
        }
        renameSteps[moved.path] = step
        return moved
    }

    /// The stack's "All Downloads" tip up for the bench's pictures, or
    /// left to the pointer again.
    func holdStackTip(_ on: Bool) { stack?.holdTip(on) }

    /// The stack's panel, for the bench to picture.
    var stackWindow: NSWindow? { stack }
    /// The chip's list, for the bench to verify its native placement.
    var listWindow: NSWindow? { panel }

    /// Downloads that aren't, for the bench to picture the stack with.
    private var pretended: [NSObject] = []

    /// A download that isn't one, part way through, for the bench.
    func pretend(name: String, from: String, got: Int64, total: Int64) {
        let token = NSObject()
        pretended.append(token)
        let id = ObjectIdentifier(token)
        fetches.insert(Fetch(id: id, name: name, from: from), at: 0)
        meter.steps[id] = Step(fraction: total > 0 ? Double(got) / Double(total) : nil, got: got, total: total)
        gaugeNow()
        toldDock()
    }

    /// The pretended ones all failed, unseen, for a picture of the red mark.
    func pretendFailed() {
        rides = false
        let ids = Set(pretended.map { ObjectIdentifier($0) })
        for i in fetches.indices where ids.contains(fetches[i].id) { fetches[i].failed = true }
        unseen = true
        gaugeNow()
    }

    /// The last pretended one landing, as a finished one does.
    func pretendLanded(_ name: String) {
        forgetPretended()
        land(name)
    }

    /// The pretended downloads gone again, as finished ones leave: the
    /// button keeps its place for the session (the bench, `forget`).
    func forgetPretended() {
        pretendTicking(false)
        let ids = Set(pretended.map { ObjectIdentifier($0) })
        pretended.removeAll()
        fetches.removeAll { ids.contains($0.id) }
        for id in ids { meter.steps[id] = nil }
        unseen = false
        gaugeNow()
        toldDock()
    }

    private var ticking: Timer?

    /// The pretended downloads coming on, ten steps a second as WebKit's
    /// are told (Gate, tell), for the bench to weigh them; nil stops.
    func pretendTicking(_ on: Bool) {
        ticking?.invalidate()
        ticking = nil
        guard on else { return }
        ticking = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var steps = self.meter.steps
                for token in self.pretended {
                    let id = ObjectIdentifier(token)
                    guard var step = steps[id], step.total > 0 else { continue }
                    step.got = min(step.total, step.got + step.total / 600)
                    step.fraction = Double(step.got) / Double(step.total)
                    if step.got >= step.total { step.got = step.total / 10 }
                    steps[id] = step
                }
                self.meter.steps = steps
                self.gaugeNow()
                self.toldDock()
            }
        }
    }

    private func forget(_ id: ObjectIdentifier) {
        if let download = downloads[id] { DownloadDestinations.release(download.downloadID) }
        arriving[id] = nil
        watches[id] = nil
        downloads[id] = nil
        resume[id] = nil
        origins[id] = nil
        heard[id] = nil
    }

    /// Where a file in the air is headed, in window coordinates: the chip
    /// while home can't be seen, the button in its place otherwise. Asked
    /// once the file has lifted off, so a slot that opened for it is landed
    /// in where it ended up. It comes down in the badge, on the button.
    var landing: CGPoint? {
        guard let height = window?.contentView?.bounds.height else { return nil }
        // The place shown now: with the tabs on top the strip's button. The
        // last button to say where it was could be the column's, past the
        // edge from before the tabs went on top, and the file fell into the
        // window's bottom-left corner instead (2026-11-02).
        let shown: Place = browser?.prefs.sidebar == false ? .strip : .side
        let home = away ? nil : frames[shown] ?? self.home
        let spot = home.map { CGPoint(x: $0.midX, y: $0.midY) } ?? chipAt
        return CGPoint(x: spot.x, y: height - spot.y)
    }
}

/// Lets a progress report through at most once in `every`, and always the
/// last one. Called on whatever thread WebKit reports on.
private final class Gate: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var last: CFTimeInterval = 0
    private let every: CFTimeInterval = 0.05

    func pass(done: Bool) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let now = CACurrentMediaTime()
        guard done || now - last >= every else { return false }
        last = now
        return true
    }
}

// MARK: - the button

/// The button where it stands, from the first download on. In the strip it
/// opens its slot before anything flies into it.
/// A download's mark wherever it is listed: the Finder's icon for its kind
/// of file, with a thin bar under it filling as it comes. The downloads
/// list and the box's downloads place draw the same one.
struct HoardFetchIcon: View {
    @ObservedObject var meter: Hoard.Meter
    let fetch: Hoard.Fetch
    var side: CGFloat = 20

    var body: some View {
        Image(nsImage: HoardList.icon(named: fetch.name))
            .resizable()
            .frame(width: side, height: side)
            .opacity(fetch.failed ? 0.45 : 1)
            .overlay(alignment: .bottom) {
                if !fetch.failed {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            // Ink, not a hairline: it has to read on a chosen row's wash too.
                            Capsule().fill(Palette.ink.opacity(0.14))
                            if let step = meter.steps[fetch.id], step.fraction == nil, step.got > 0 {
                                HoardUnsized(width: geo.size.width)
                            } else {
                                Capsule().fill(Palette.ink).frame(width: geo.size.width * (meter.steps[fetch.id]?.fraction ?? 0))
                            }
                        }
                    }
                    .frame(height: side / 10)
                    .offset(y: side * 0.15)
                }
            }
    }
}

/// A download whose size nobody said: a short piece of the bar running
/// across it, so a long file still reads as coming.
/// Still, a third of the way in, when motion is reduced.
struct HoardUnsized: View {
    let width: CGFloat
    @State private var running = false
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let piece = width / 3
        Capsule()
            .fill(Palette.ink)
            .frame(width: piece)
            .offset(x: still ? piece : running ? width : -piece)
            .frame(width: width, alignment: .leading)
            .clipped()
            .onAppear {
                guard !still else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { running = true }
            }
    }
}

/// A download's progress in words, kept up with its meter.
struct HoardFetchWords: View {
    @ObservedObject var meter: Hoard.Meter
    let fetch: Hoard.Fetch

    var body: some View {
        Text(HoardList.said(fetch, step: meter.steps[fetch.id] ?? Hoard.Step()))
    }
}

struct HoardSlot: View {
    @ObservedObject var hoard: Hoard
    let place: Hoard.Place
    /// A split's half behind the one in front, the pointer off its band:
    /// away with the doors beside it, unless a download wants to be seen.
    var quiet = false

    var body: some View {
        let away = quiet && !hoard.calling
        // The column's foot always has it; the strip and the address bar
        // only from the session's first download.
        if place == .side || hoard.shown {
            HoardButton(hoard: hoard, place: place)
                .opacity(away ? 0 : 1)
                .allowsHitTesting(!away)
                // In the strip it grows in once, at the first download. Going
                // it goes at once: a copy fading out while another comes in
                // (the look changed, the tabs moved) would still report its
                // frame and take the place from the new one (frames, claim).
                .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .identity))
        }
    }
}

struct HoardButton: View {
    @ObservedObject var hoard: Hoard
    let place: Hoard.Place

    @State private var hovering = false
    @State private var reportID = UUID()
    @State private var lastFrame: CGRect?
    @Environment(\.tone) private var tone
    /// The row's doors: the band's are larger, and the circle with them.
    @Environment(\.doorSize) private var size

    /// In the column's foot, 8 in from the window's 18 corner, a row's
    /// corner; in the strip, a control's.
    private var corner: CGFloat { place == .side ? SideBar.radius : Radius.control }

    var body: some View {
        let scale = HoardMark.scale(in: size)
        let side = HoardMark.side * scale, line = HoardMark.line * scale

        Button { hoard.press(place) } label: {
            ZStack {
                // The circle is the arrow's, in its ink and at its weight.
                // While the badge has the place both are gone; they come
                // back from a little larger as it shrinks into them.
                let away = hoard.badged && hoard.openAt == nil
                Group {
                    Circle()
                        .stroke(ink, lineWidth: line)
                    HoardMark(pose: .arrow)
                        .stroke(ink, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                }
                .opacity(away ? 0 : 1)
                .scaleEffect(away ? 1.25 : 1)
                .animation(away ? nil : .timingCurve(0.3, 1.5, 0.5, 1, duration: 0.28), value: away)
                .compositingGroup()
                // A file lands: the mark takes it in, down a little and back.
                .keyframeAnimator(initialValue: CGFloat(0), trigger: hoard.bumps) { mark, dip in
                        mark.offset(y: dip)
                    } keyframes: { _ in
                        CubicKeyframe(2, duration: 0.1)
                        SpringKeyframe(0, duration: 0.3, spring: Spring(response: 0.26, dampingRatio: 0.62))
                    }
            }
            .frame(width: side, height: side)
            .frame(width: size.side, height: size.side)
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel("Downloads")
        .background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(hoard.openAt == place ? Palette.wash(on: tone) : (hovering ? Palette.hover(on: tone) : .clear))
        )
        // In the button's place and past its edges, taking no presses and no room.
        .overlay {
            HoardBadge(hoard: hoard, gauge: hoard.gauge, top: place == .strip, chip: place == .chip)
                .frame(width: HoardBadge.room, height: HoardBadge.room)
                .allowsHitTesting(false)
        }
        .onHover { inside in
            hovering = inside
            // Two halves' bands have one each: the one under the pointer
            // is where its list opens and files land.
            if inside, let lastFrame { claim(lastFrame) }
            hoard.hover(place, inside)
        }
        // The column's says what a click does beside it, under its cards.
        // With nothing downloaded there are no cards, and the tip is its own.
        .keyTip(place == .side ? (hoard.anything ? "" : "All Downloads") : "Downloads", shortcut: "Show Downloads")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            lastFrame = frame
            if Store.testing { hoard.buttonFrames[reportID] = (place, frame) }
            claim(frame)
        }
        .onDisappear {
            if hoard.framers[place] == reportID {
                hoard.frames.removeValue(forKey: place)
                hoard.framers.removeValue(forKey: place)
            }
            hoard.buttonFrames.removeValue(forKey: reportID)
        }
    }

    /// This button is where its place's list opens and files land.
    private func claim(_ frame: CGRect) {
        hoard.frames[place] = frame
        hoard.framers[place] = reportID
        if place != .chip {
            hoard.home = frame
        }
    }

    private var ink: Color {
        return hovering ? Palette.ink.opacity(0.88) : Palette.muted(on: tone)
    }
}

/// The button's mark: a stem and a three-point stroke.
struct HoardMark: Shape {
    /// The circle round it, and what it is drawn in: the size and weight of
    /// a circle in the icons beside it, 11 point Central glyphs on a 15
    /// point box, whose circles are 18 of its 24 across in a stroke of 2.
    static let side: CGFloat = 11.5
    static let line: CGFloat = 1.25

    /// Both, in a row whose doors are larger, the address bar's 13 point
    /// glyphs: grown as the glyphs beside it are, so it reads their size
    /// and weight there too (feedback 56, 66).
    static func scale(in door: Door.Size) -> CGFloat { door.glyph / Door.Size().glyph }

    /// Stem from, stem to, then the head's three points, on a 24 point
    /// grid whose circle, through the stroke, is 9.2 round the middle.
    struct Pose: VectorArithmetic {
        var v: SIMD16<Double>

        static let arrow = Pose(12, 7.2, 12, 16.3, 8.6, 12.9, 12, 16.3, 15.4, 12.9)

        init(_ p: Double...) {
            v = .zero
            for (i, x) in p.enumerated() { v[i] = x }
        }
        private init(v: SIMD16<Double>) { self.v = v }

        static var zero: Pose { Pose(v: .zero) }
        static func + (a: Pose, b: Pose) -> Pose { Pose(v: a.v + b.v) }
        static func - (a: Pose, b: Pose) -> Pose { Pose(v: a.v - b.v) }
        mutating func scale(by rhs: Double) { v *= rhs }
        var magnitudeSquared: Double { (v * v).sum() }
    }

    var pose: Pose
    var animatableData: Pose {
        get { pose }
        set { pose = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let k = rect.width / 18.4
        let v = pose.v
        func at(_ i: Int) -> CGPoint {
            CGPoint(x: rect.midX + (v[i] - 12) * k, y: rect.midY + (v[i + 1] - 12) * k)
        }
        var path = Path()
        path.move(to: at(0))
        path.addLine(to: at(2))
        path.move(to: at(4))
        path.addLine(to: at(6))
        path.addLine(to: at(8))
        return path
    }
}

/// The badge's colors, worked out from the space's own: on a light space a
/// nearly white disc of its hue, a paler track, ring and arrow a darker and
/// saturated shade; on a dark space a dark disc and a light ring.
struct HoardDialInks: Equatable {
    let ring: CGColor
    let track: CGColor
    let disc: CGColor
    /// A failure's, the same whatever the space.
    static let bad = CGColor(srgbRed: 217 / 255, green: 45 / 255, blue: 32 / 255, alpha: 1)

    init(tone: Tone?, look: NSAppearance?) {
        let dark = tone.map { $0.scheme == .dark }
            ?? (look?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let page = tone?.page.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        page.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // A gray space stays gray; any color goes as far as it can.
        let colored = min(1, saturation * 4)
        if dark {
            ring = Self.color(hue, 0.04 * colored, 0.95)
            track = Self.color(hue, 0.12 * colored, 0.44)
            disc = Self.color(hue, 0.15 * colored, 0.11)
        } else {
            disc = Self.color(hue, 0.05 * colored, 0.98)
            track = Self.color(hue, 0.20 * colored, 0.88)
            // Down from bright until it reads on the disc, whichever hue:
            // a yellow goes further than a blue.
            let chroma = 0.85 * colored
            var value: CGFloat = 0.85
            while value > 0.3, Self.contrast(Self.color(hue, chroma, value), disc) < 5 { value -= 0.02 }
            ring = Self.color(hue, chroma, value)
        }
    }

    private static func color(_ hue: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat) -> CGColor {
        NSColor(colorSpace: .sRGB, hue: hue, saturation: saturation, brightness: brightness, alpha: 1).cgColor
    }

    private static func luminance(_ color: CGColor) -> CGFloat {
        let parts = color.components ?? [0, 0, 0]
        func line(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * line(parts[0]) + 0.7152 * line(parts[1]) + 0.0722 * line(parts[2])
    }

    private static func contrast(_ a: CGColor, _ b: CGColor) -> CGFloat {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// The disc, its track, the ring and the arrow or a failure's cross, in
/// layers: nothing about it goes through SwiftUI, and a step of the ring is
/// a plain change with no animation.
final class HoardDial: CALayer {
    static let side: CGFloat = 19
    /// A ring just begun: a dot at twelve o'clock.
    private static let least: CGFloat = 0.03

    private let disc = CAShapeLayer()
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let mark = CAShapeLayer()
    private var spinning = false
    private var failed = false
    private(set) var inks: HoardDialInks?

    /// Drawn top down, on a 19 point grid scaled to `size`: its host's
    /// canvas is flipped, a host that isn't flips the dial.
    init(size: CGFloat) {
        super.init()
        bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let k = size / Self.side
        let middle = CGPoint(x: size / 2, y: size / 2)
        let r = 8.6 * k
        let circle = CGPath(ellipseIn: CGRect(x: middle.x - r, y: middle.y - r, width: r * 2, height: r * 2), transform: nil)
        for part in [disc, track, arc, mark] {
            part.frame = bounds
            part.actions = ["strokeEnd": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull(), "path": NSNull()]
            part.fillColor = nil
            addSublayer(part)
        }
        disc.path = circle
        track.path = circle
        track.lineWidth = 1.1 * k
        let round = CGMutablePath()
        // Down is plus here, so rising angles run clockwise from twelve.
        round.addArc(center: middle, radius: r, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: false)
        arc.path = round
        arc.lineWidth = 1.5 * k
        arc.lineCap = .round
        arc.strokeEnd = Self.least
        mark.lineWidth = 1.5 * k
        mark.lineCap = .round
        mark.lineJoin = .round
        setMark(failed: false)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private func setMark(failed: Bool) {
        let k = bounds.width / Self.side
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
        let line = CGMutablePath()
        if failed {
            line.move(to: at(6.6, 6.6)); line.addLine(to: at(12.4, 12.4))
            line.move(to: at(12.4, 6.6)); line.addLine(to: at(6.6, 12.4))
        } else {
            line.move(to: at(9.5, 5.4)); line.addLine(to: at(9.5, 13.4))
            line.move(to: at(6.2, 10.2)); line.addLine(to: at(9.5, 13.5)); line.addLine(to: at(12.8, 10.2))
        }
        mark.path = line
    }

    func wear(_ inks: HoardDialInks) {
        self.inks = inks
        paint()
    }

    private func paint() {
        guard let inks else { return }
        disc.fillColor = inks.disc
        track.strokeColor = inks.track
        arc.strokeColor = failed ? HoardDialInks.bad : inks.ring
        mark.strokeColor = failed ? HoardDialInks.bad : inks.ring
    }

    /// `whole` nil: no size to go by, a short arc goes round. Still, where
    /// motion is reduced.
    func show(whole: Double?, failed: Bool, still: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if failed != self.failed {
            self.failed = failed
            setMark(failed: failed)
            paint()
        }
        if failed {
            stop()
            arc.strokeEnd = 0.4
        } else if let whole {
            stop()
            arc.strokeEnd = max(Self.least, CGFloat(whole))
        } else {
            arc.strokeEnd = 0.22
            if !spinning, !still { spin() }
        }
        CATransaction.commit()
    }

    private func spin() {
        spinning = true
        let round = CABasicAnimation(keyPath: "transform.rotation.z")
        round.fromValue = 0
        round.toValue = CGFloat.pi * 2
        round.duration = 1
        round.repeatCount = .infinity
        round.isRemovedOnCompletion = false
        arc.add(round, forKey: "spin")
    }

    private func stop() {
        spinning = false
        arc.removeAnimation(forKey: "spin")
    }

    /// A layer that left the window lost what it was playing.
    func resume() { if spinning { spin() } }

    func scale(to value: CGFloat) {
        contentsScale = value
        for part in sublayers ?? [] { part.contentsScale = value }
    }
}

/// What has the button's place while anything comes: the dial, in the space's
/// colors. Then the file's own icon, risen out of the button, its corner on
/// where the circle's edge was, until the pointer comes. Over the button,
/// never in its way.
struct HoardBadge: NSViewRepresentable {
    /// Room for the view, more than the disc and the icon, so that nothing is
    /// cut; it takes no space, standing in an overlay.
    static let room: CGFloat = 44

    @ObservedObject var hoard: Hoard
    let gauge: Hoard.Gauge
    /// With the tabs on top: the file goes to the upper left, smaller.
    let top: Bool
    /// The chip's: the file goes with it once it has settled.
    var chip = false
    @Environment(\.accessibilityReduceMotion) private var still
    @Environment(\.tone) private var tone
    @Environment(\.colorScheme) private var scheme

    private var state: HoardBadgeView.State {
        // Its row has it while the list is up, the carrier on the way.
        if (hoard.openAt != nil && (hoard.openAt != .side || hoard.stackOut)) || hoard.carrying { return .none }
        if let waiting = hoard.waiting { return chip && hoard.settled ? .gone : .file(waiting) }
        guard hoard.badged else { return .none }
        if hoard.going.isEmpty, !hoard.filling { return .failed }
        return .going(hoard.going.count)
    }

    func makeNSView(context: Context) -> HoardBadgeView { HoardBadgeView(gauge: gauge) }

    func updateNSView(_ view: HoardBadgeView, context: Context) {
        view.top = top
        view.wear(HoardDialInks(tone: tone, look: NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)))
        view.show(state, still: still || Ring.stillForTests, quietly: hoard.returned)
        if case .file(let name) = state {
            hoard.picture(named: name) { [weak view] image in view?.picture(image, named: name) }
        }
    }
}

/// The badge's layers. It listens to the Gauge itself, ten plain steps a
/// second, and its pop and the file's rise play in the render server.
final class HoardBadgeView: NSView {
    enum State: Equatable {
        case none
        case going(Int)
        case failed
        case file(String)
        /// Fading with the chip as it goes home.
        case gone
    }

    /// The file's icon: the box the document stands in, 22 by 28 inside it.
    static let icon: CGFloat = 28
    static let topScale: CGFloat = 0.7
    /// Its middle from the button's: its lower left corner on the circle's
    /// upper right; with the tabs on top, its lower right on the upper left.
    static func fileAt(top: Bool) -> CGSize {
        top ? CGSize(width: -10, height: -9.5) : CGSize(width: 13, height: -16)
    }

    private static let margin: CGFloat = 3

    var top = false
    private let gauge: Hoard.Gauge
    private var listening: AnyCancellable?
    private var state = State.none
    private var still = false

    // Top down, as RingView's: AppKit decides the flip of a hosting view's own.
    private let canvas = CALayer()
    private let dial = HoardDial(size: HoardDial.side)
    private let file = CALayer()
    private let count = CALayer()
    private let number = CATextLayer()

    init(gauge: Hoard.Gauge) {
        self.gauge = gauge
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        canvas.isGeometryFlipped = true
        layer?.addSublayer(canvas)
        canvas.addSublayer(file)
        canvas.addSublayer(dial)
        dial.opacity = 0
        file.opacity = 0
        file.bounds = CGRect(x: 0, y: 0, width: Self.icon, height: Self.icon)
        file.contentsGravity = .resizeAspect
        file.shadowColor = .black
        file.shadowOpacity = 0.28
        file.shadowRadius = 3
        file.shadowOffset = CGSize(width: 0, height: 1)

        // The count, on the closed badge's own corner.
        count.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        count.position = CGPoint(x: HoardDial.side - 1, y: 2)
        count.cornerRadius = 6
        number.frame = CGRect(x: 0, y: 1.2, width: 12, height: 11)
        number.font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
        number.fontSize = 8.5
        number.alignmentMode = .center
        count.addSublayer(number)
        count.isHidden = true
        dial.addSublayer(count)
        listening = gauge.$whole.sink { [weak self] whole in
            MainActor.assumeIsolated { self?.heard(whole) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func wear(_ inks: HoardDialInks) {
        guard dial.inks != inks else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dial.wear(inks)
        count.backgroundColor = inks.ring
        number.foregroundColor = inks.disc
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        place()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        place()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        place()
        let scale = window?.backingScaleFactor ?? 2
        dial.scale(to: scale)
        for part in [canvas, file, count, number] { part.contentsScale = scale }
        if window != nil { dial.resume() }
    }

    /// The dial in the middle of the view; the file off it, kept in the window.
    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.frame = bounds
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        dial.position = middle
        file.position = fileSpot(middle)
        file.transform = top ? CATransform3DMakeScale(Self.topScale, Self.topScale, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    private func fileSpot(_ middle: CGPoint) -> CGPoint {
        let at = Self.fileAt(top: top)
        var spot = CGPoint(x: middle.x + at.width, y: middle.y + at.height)
        if let content = window?.contentView {
            let half = Self.icon / 2 * (top ? Self.topScale : 1)
            let onWindow = convert(middle, to: nil)
            let room = content.bounds.width - onWindow.x - at.width - half
            spot.x += min(0, room - Self.margin)
            spot.x += max(0, Self.margin - (onWindow.x + at.width - half))
            let above = content.bounds.height - onWindow.y + at.height - half
            spot.y += max(0, Self.margin - above)
        }
        return spot
    }

    private func heard(_ whole: Double?) {
        if case .going = state { dial.show(whole: whole, failed: false, still: still) }
    }

    func show(_ next: State, still: Bool, quietly: Bool) {
        self.still = still
        let was = state
        guard next != was else { return }
        state = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch next {
        case .none:
            // Its row, or nothing, has it: gone at once if the carrier takes
            // it, as the carrier starts where it stood.
            dial.removeAllAnimations()
            file.removeAllAnimations()
            dial.opacity = 0
            file.opacity = 0
        case .going(let many):
            count.isHidden = many < 2
            if many > 1 { number.string = "\(many)" }
            dial.show(whole: gauge.whole, failed: false, still: still)
            file.opacity = 0
            if !isShown(was) {
                dial.opacity = 1
                if !quietly { pop() }
            }
        case .failed:
            count.isHidden = true
            dial.show(whole: nil, failed: true, still: still)
            file.opacity = 0
            if !isShown(was) {
                dial.opacity = 1
                if !quietly { pop() }
            }
        case .file(let name):
            file.contents = HoardList.icon(named: name).layerContents(forContentsScale: window?.backingScaleFactor ?? 2)
            place()
            file.opacity = 1
            rise(from: isShown(was))
            if isShown(was) { shrink() }
            dial.opacity = 0
        case .gone:
            // On the chip's own curve and time (Motion.depart).
            for part in [file, dial] where part.opacity > 0 {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = part.presentation()?.opacity ?? 1
                fade.toValue = 0
                fade.duration = still ? 0 : 0.15
                fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.4)
                part.add(fade, forKey: "gone")
                part.opacity = 0
            }
        }
        CATransaction.commit()
    }

    func picture(_ image: NSImage, named name: String) {
        guard state == .file(name) else { return }
        file.contents = image.layerContents(forContentsScale: window?.backingScaleFactor ?? 2)
    }

    private func isShown(_ state: State) -> Bool {
        switch state {
        case .going, .failed: true
        case .none, .file, .gone: false
        }
    }

    /// In place when the disc lands: from 0.6 to whole, with a little give.
    private func pop() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = still ? 0.15 : 0.12
        dial.add(fade, forKey: "fade")
        guard !still else { return }
        let curve = Hoard.springCurve
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.6
        grow.toValue = 1
        grow.duration = 0.3
        grow.timingFunction = CAMediaTimingFunction(controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2))
        dial.add(grow, forKey: "pop")
    }

    /// The circle back into the button, as small as its circle, and gone.
    private func shrink() {
        guard !still else { return }
        let curve = Hoard.rideCurve
        let small = CABasicAnimation(keyPath: "transform.scale")
        small.fromValue = 1
        small.toValue = 13.0 / 19
        small.duration = Hoard.ride
        small.timingFunction = CAMediaTimingFunction(controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.14
        dial.add(small, forKey: "shrink")
        dial.add(fade, forKey: "fade")
    }

    /// Up out of the middle of the button, past its place and back.
    private func rise(from dialShown: Bool) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        file.add(fade, forKey: "fade")
        guard !still else { return }
        let curve = Hoard.springCurve
        let timing = CAMediaTimingFunction(controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2))
        let path = CABasicAnimation(keyPath: "position")
        path.fromValue = NSValue(point: CGPoint(x: bounds.midX, y: bounds.midY))
        path.toValue = NSValue(point: file.position)
        path.duration = Hoard.spring
        path.timingFunction = timing
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = top ? Self.topScale : 1
        grow.duration = Hoard.spring
        grow.timingFunction = timing
        file.add(path, forKey: "rise")
        file.add(grow, forKey: "grow")
    }
}

/// A download's ring in its row, each row with its own, no count.
struct HoardRowDial: NSViewRepresentable {
    let fraction: Double?
    let failed: Bool
    /// Coming, with no size said: the short arc goes round.
    let unknown: Bool
    let side: CGFloat
    let tone: Tone?
    @Environment(\.accessibilityReduceMotion) private var still

    func makeNSView(context: Context) -> RowDialView { RowDialView(side: side) }

    func updateNSView(_ view: RowDialView, context: Context) {
        view.dial.wear(HoardDialInks(tone: tone, look: view.effectiveAppearance))
        view.dial.show(whole: unknown ? nil : (fraction ?? 0), failed: failed, still: still || Ring.stillForTests)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RowDialView, context: Context) -> CGSize? {
        CGSize(width: side, height: side)
    }

    final class RowDialView: NSView {
        let dial: HoardDial
        private let canvas = CALayer()

        init(side: CGFloat) {
            dial = HoardDial(size: side)
            super.init(frame: .zero)
            layer = CALayer()
            wantsLayer = true
            canvas.isGeometryFlipped = true
            layer?.addSublayer(canvas)
            canvas.addSublayer(dial)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            canvas.frame = bounds
            dial.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            dial.scale(to: window?.backingScaleFactor ?? 2)
            if window != nil { dial.resume() }
        }
    }
}

/// The row a badge or a file rides into says where its icon stands, in its
/// panel. Read off the row's place in layout, not where a rise has it now.
struct HoardRowSpot: ViewModifier {
    let hoard: Hoard
    let on: Bool
    /// 0: read off a whole row, whose icon stands at its leading edge; else
    /// off the icon itself.
    let inset: CGFloat
    let side: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        if on {
            content.background {
                HoardRowSpotReader(hoard: hoard, inset: inset, side: side)
            }
        } else {
            content
        }
    }
}

private struct HoardRowSpotReader: NSViewRepresentable {
    let hoard: Hoard
    let inset: CGFloat
    let side: CGFloat

    func makeNSView(context: Context) -> Reader { Reader() }

    func updateNSView(_ view: Reader, context: Context) {
        view.hoard = hoard
        view.inset = inset
        view.side = side
        view.tell()
    }

    /// In the panel's own coordinates, top down, whenever laid out.
    final class Reader: NSView {
        weak var hoard: Hoard?
        var inset: CGFloat = 0
        var side: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            tell()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tell()
        }

        func tell() {
            guard let window, let content = window.contentView else { return }
            let box = convert(bounds, to: nil)
            let y = content.bounds.height - box.midY - side / 2
            let x = inset == 0 ? box.minX : box.midX - side / 2
            hoard?.rowSpot = ({ [weak window] in window }, CGRect(x: x, y: y, width: side, height: side))
        }
    }
}

/// A file come in with the list open: it grows where the row's ring was.
struct HoardFileGrows: ViewModifier {
    let keep: Keep
    let hoard: Hoard
    @State private var small = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(small ? 0.45 : 1)
            .opacity(small ? 0 : 1)
            .onAppear {
                guard hoard.openAt != nil, !hoard.carrying, abs(keep.date.timeIntervalSinceNow) < 1.5,
                      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                small = true
                let curve = Hoard.springCurve
                DispatchQueue.main.async {
                    withAnimation(.timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: Hoard.spring)) { small = false }
                }
            }
    }
}

/// What rides from the button into its row and back, or fades in the row: a
/// panel over the list, up only for that moment, since the button is in the
/// window and the row in a panel above it.
final class HoardCarrier: NSPanel {
    enum Art {
        case dial(HoardDialInks, Double?, Bool)
        case file(String, URL?)
    }

    private weak var parentRef: NSWindow?
    private var generation = 0

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        contentView = NSView()
        contentView?.wantsLayer = true
    }

    func look(over window: NSWindow) {
        parentRef?.removeChildWindow(self)
        // Last in, so over the list.
        window.addChildWindow(self, ordered: .above)
        parentRef = window
    }

    /// On screen, each point the middle of what is carried, and its size.
    func fly(_ art: Art, from: CGPoint, side fromSide: CGFloat, to: CGPoint, side toSide: CGFloat, fading: Bool = false, done: @escaping () -> Void) {
        generation += 1
        let generation = generation
        let pad = max(fromSide, toSide) + 8
        let box = NSRect(x: min(from.x, to.x) - pad, y: min(from.y, to.y) - pad,
                         width: abs(from.x - to.x) + pad * 2, height: abs(from.y - to.y) + pad * 2)
        setFrame(box, display: false)
        let scale = parentRef?.backingScaleFactor ?? 2
        guard let host = contentView?.layer else { done(); return }
        host.sublayers?.forEach { $0.removeFromSuperlayer() }
        let piece: CALayer
        let drawn = max(fromSide, toSide)
        switch art {
        case .dial(let inks, let whole, let failed):
            let dial = HoardDial(size: drawn)
            dial.isGeometryFlipped = true
            dial.wear(inks)
            dial.show(whole: whole ?? 0.22, failed: failed, still: true)
            dial.scale(to: scale)
            piece = dial
        case .file(let name, let url):
            let file = CALayer()
            file.bounds = CGRect(x: 0, y: 0, width: drawn, height: drawn)
            file.contentsGravity = .resizeAspect
            file.contentsScale = scale
            file.contents = HoardList.icon(named: name).layerContents(forContentsScale: scale)
            if let url {
                HoardPictures.shared.image(url) { [weak file] image in
                    file?.contents = image.layerContents(forContentsScale: scale)
                }
            }
            piece = file
        }
        let start = CGPoint(x: from.x - box.minX, y: from.y - box.minY)
        let end = CGPoint(x: to.x - box.minX, y: to.y - box.minY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        piece.position = end
        piece.transform = CATransform3DMakeScale(toSide / drawn, toSide / drawn, 1)
        if fading { piece.opacity = 0 }
        host.addSublayer(piece)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.orderOut(nil)
                done()
            }
        }
        let curve = Hoard.rideCurve
        let timing = CAMediaTimingFunction(controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2))
        let along = CABasicAnimation(keyPath: "position")
        along.fromValue = NSValue(point: start)
        along.toValue = NSValue(point: end)
        let size = CABasicAnimation(keyPath: "transform.scale")
        size.fromValue = fromSide / drawn
        size.toValue = toSide / drawn
        for part in [along, size] {
            part.duration = Hoard.ride
            part.timingFunction = timing
        }
        piece.add(along, forKey: "along")
        piece.add(size, forKey: "size")
        if fading {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = Hoard.ride
            piece.add(fade, forKey: "fade")
        }
        CATransaction.commit()
        orderFront(nil)
    }
}


// MARK: - the chip

/// The button, out of the edge its place is behind, while that place can't
/// be seen: at the foot of the window's left edge. The column's stays out;
/// the strip's comes out only while something is going.
struct HoardChip: View {
    @ObservedObject var hoard: Hoard
    let away: Bool
    /// The tabs are on top: the button's place is the strip or the band.
    /// Kept for the callers; the chip comes out the same way either way.
    let top: Bool
    /// In the corner the column's foot would be in: its own edge's.
    var flank: Flank = .left

    var body: some View {
        GeometryReader { geo in
            // Never at rest over the page: with the column put away, the tabs
            // on top or a page that has the screen, the chip comes out only
            // while a download is going, landing, failed or its list is up.
            let out = away && hoard.calling
            let left = flank == .left
            let spot = CGPoint(x: left ? 10 + 15 : geo.size.width - 10 - 15, y: geo.size.height - 10 - 15)

            if hoard.shown {
                HoardButton(hoard: hoard, place: .chip)
                    .padding(2)
                    // The line under the button's own overlay: the file rising
                    // over the chip's corner stands over it, not under it.
                    .background(
                        RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous)
                            .fill(Palette.ground) // design: the chip's own plate as it was, its line moved under the file
                            .strokeBorder(Palette.hairline, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
                    // Out of its own edge and back into it, the way home.
                    .offset(out ? .zero : CGSize(width: left ? -60 : 60, height: 0))
                    .opacity(out ? 1 : 0)
                    .allowsHitTesting(out)
                    .animation(out ? Motion.arrive : Motion.depart, value: out)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: left ? .bottomLeading : .bottomTrailing)
            }
            Color.clear
                .allowsHitTesting(false)
                .onChange(of: spot, initial: true) { _, spot in hoard.chipAt = spot }
        }
        .onChange(of: away) { _, away in
            // Home again with the chip's list up: it goes with the chip.
            if !away, hoard.openAt == .chip { hoard.openAt = nil }
        }
    }
}

// MARK: - the flight

/// Where files fly: a view over the whole window that takes no clicks and
/// draws nothing of its own, only the layers of whatever is in the air.
struct HoardSky: NSViewRepresentable {
    let hoard: Hoard

    func makeNSView(context: Context) -> HoardSkyView {
        let view = HoardSkyView()
        hoard.sky = view
        return view
    }

    func updateNSView(_ view: HoardSkyView, context: Context) {
        hoard.sky = view
    }
}

extension CGPoint {
    /// Both coordinates numbers: what a layer's position may be.
    var isFinite: Bool { x.isFinite && y.isFinite }
}

final class HoardSkyView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Thrown from where it was clicked: a dark disc with a white arrow
    /// lifts off the page, small and faint, then flies the arc every file
    /// flew before 2026-10-30 into the button, brought back on 2026-11-01. Both points in window coordinates; where it lands is
    /// asked once it has lifted off.
    func fly(from start: CGPoint, name: String, to landing: @escaping () -> CGPoint?, landed: @escaping () -> Void) {
        // Core Animation raises on a position that isn't a number (0.0.21
        // aborted here, crash #23): a click point the sky can't place, as
        // when it has no size yet, flies from nowhere and the button only
        // gives, as a download with no click does.
        let from = convert(start, from: nil)
        guard let host = layer, from.isFinite else { landed(); return }
        let disc = CALayer()
        let side = HoardSkyView.throwSide
        disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        disc.contentsScale = window?.backingScaleFactor ?? 2
        disc.contents = HoardSkyView.throwArt(scale: disc.contentsScale)
        disc.shadowColor = CGColor(srgbRed: 90 / 255, green: 190 / 255, blue: 170 / 255, alpha: 1)
        disc.shadowOpacity = 0.55
        disc.shadowRadius = 5
        disc.shadowOffset = .zero
        disc.shadowPath = CGPath(ellipseIn: disc.bounds, transform: nil)
        let lifted = CGPoint(x: from.x, y: from.y + 6)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.position = lifted
        host.addSublayer(disc)
        CATransaction.commit()

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let rise = CABasicAnimation(keyPath: "position")
        rise.fromValue = NSValue(point: from)
        rise.toValue = NSValue(point: lifted)
        let pop = CAAnimationGroup()
        for part in [grow, fade, rise] { part.duration = Hoard.lift }
        pop.animations = [grow, fade, rise]
        pop.duration = Hoard.lift
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        disc.add(pop, forKey: "pop")

        DispatchQueue.main.asyncAfter(deadline: .now() + Hoard.lift) { [weak self, weak disc] in
            guard let self, let disc else { landed(); return }
            let end = landing().map { self.convert($0, from: nil) }.flatMap { $0.isFinite ? $0 : nil } ?? lifted
            let along = CAKeyframeAnimation(keyPath: "position")
            along.path = HoardSkyView.arc(from: lifted, to: end)
            along.calculationMode = .paced
            // Down to the badge's size as it comes into the button.
            let shrink = CAKeyframeAnimation(keyPath: "transform.scale")
            shrink.values = [1, 1, HoardDial.side / side]
            shrink.keyTimes = [0, 0.55, 1]
            let out = CAKeyframeAnimation(keyPath: "opacity")
            out.values = [1, 1, 0]
            out.keyTimes = [0, 0.94, 1]
            let arc = CAAnimationGroup()
            for part in [along, shrink, out] as [CAAnimation] { part.duration = Hoard.arc }
            arc.animations = [along, shrink, out]
            arc.duration = Hoard.arc
            arc.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock {
                disc.removeFromSuperlayer()
                landed()
            }
            disc.position = end
            disc.opacity = 0
            disc.add(arc, forKey: "arc")
            CATransaction.commit()
        }
    }

    /// The size it is drawn at.
    private static let throwSide: CGFloat = 24

    /// The disc: near black, the white arrow. Drawn once per flight.
    private static func throwArt(scale: CGFloat) -> CGImage? {
        let side = throwSide
        let pixels = Int(side * scale)
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(srgbRed: 13 / 255, green: 26 / 255, blue: 20 / 255, alpha: 1))
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
        // The 19 point drawing, y up.
        let k = side / 19
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: (19 - y) * k) }
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(1.7 * k)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: at(9.5, 5))
        context.addLine(to: at(9.5, 13.4))
        context.move(to: at(6, 10.2))
        context.addLine(to: at(9.5, 13.6))
        context.addLine(to: at(13, 10.2))
        context.strokePath()
        return context.makeImage()
    }

    /// The way anything flies into a button: down to the column's foot it
    /// rises first and falls in; up into the strip it goes along and then
    /// up, with hardly a rise.
    static func arc(from start: CGPoint, to end: CGPoint) -> CGPath {
        let control = end.y > start.y + 40
            ? CGPoint(x: start.x + (end.x - start.x) * 0.7, y: start.y + 10)
            : CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + 90)
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }

    /// An extension just added from the store: its own icon, from where
    /// the store's page shows its picture (`from`, in the window), lifted
    /// off and flown on a file's arc into the puzzle, going from the
    /// picture's size to a list icon's. Where it lands is asked once it has
    /// lifted off; with nowhere to land it fades where it rose, and
    /// `landed` hears false.
    func fly(icon: NSImage, from start: CGRect, to landing: @escaping () -> CGPoint?, landed: @escaping (Bool) -> Void) {
        let rect = convert(start, from: nil)
        guard let host = layer, start.width > 0, rect.origin.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0
        else { landed(false); return }
        let picture = CALayer()
        picture.bounds = CGRect(origin: .zero, size: rect.size)
        picture.contentsGravity = .resizeAspect
        picture.contentsScale = window?.backingScaleFactor ?? 2
        picture.contents = icon.layerContents(forContentsScale: picture.contentsScale)
        let from = CGPoint(x: rect.midX, y: rect.midY)
        let lifted = CGPoint(x: from.x, y: from.y + 6)
        let lift: CGFloat = 1.06

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.position = lifted
        picture.transform = CATransform3DMakeScale(lift, lift, 1)
        host.addSublayer(picture)
        CATransaction.commit()

        let rise = CABasicAnimation(keyPath: "position")
        rise.fromValue = NSValue(point: from)
        rise.toValue = NSValue(point: lifted)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = lift
        let pop = CAAnimationGroup()
        for part in [rise, grow] { part.duration = Hoard.lift }
        pop.animations = [rise, grow]
        pop.duration = Hoard.lift
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        picture.add(pop, forKey: "pop")

        DispatchQueue.main.asyncAfter(deadline: .now() + Hoard.lift) { [weak self, weak picture] in
            guard let self, let picture else { landed(false); return }
            let end = landing().map { self.convert($0, from: nil) }.flatMap { $0.isFinite ? $0 : nil }
            let small = 16 / max(rect.width, rect.height)
            let along = CAKeyframeAnimation(keyPath: "position")
            along.path = HoardSkyView.arc(from: lifted, to: end ?? lifted)
            along.calculationMode = .paced
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = lift
            shrink.toValue = end == nil ? lift : small
            let out = CAKeyframeAnimation(keyPath: "opacity")
            out.values = end == nil ? [1, 0] : [1, 1, 0]
            out.keyTimes = end == nil ? [0, 1] : [0, 0.9, 1]
            let arc = CAAnimationGroup()
            for part in [along, shrink, out] as [CAAnimation] { part.duration = Hoard.arc }
            arc.animations = [along, shrink, out]
            arc.duration = Hoard.arc
            arc.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock {
                picture.removeFromSuperlayer()
                landed(end != nil)
            }
            picture.position = end ?? lifted
            picture.opacity = 0
            picture.transform = CATransform3DMakeScale(end == nil ? lift : small, end == nil ? lift : small, 1)
            picture.add(arc, forKey: "arc")
            CATransaction.commit()
        }
    }
}

// MARK: - the list

/// What is going and what came last, in a Tray over the button, built the
/// way the extensions list is, row for row, so the two read as one kind of
/// thing. All of them are the downloads page's, one row away.
struct HoardList: View {
    /// Concentric: the panel's curve less its inset is the rows' curve, and
    /// thumbs, words and the divider share one left edge (`edge`).
    static let corner = Radius.floating
    static let inset: CGFloat = 6
    static let inner = Radius.control
    static let rowSide: CGFloat = 6
    static var edge: CGFloat { inset + rowSide }

    @ObservedObject var hoard: Hoard
    @ObservedObject var loot: Loot
    let browser: Browser

    private var kept: [Keep] {
        Array(loot.kept.prefix(max(0, 4 - hoard.fetches.count)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                if hoard.fetches.isEmpty && kept.isEmpty {
                    Text("Nothing downloaded yet")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, HoardList.rowSide)
                        .padding(.vertical, 6)
                }
                ForEach(hoard.fetches) { fetch in
                    FetchRow(hoard: hoard, meter: hoard.meter, fetch: fetch)
                }
                ForEach(kept) { keep in
                    KeptRow(hoard: hoard, first: hoard.fetches.isEmpty && keep.id == kept.first?.id, keep: keep, open: { loot.open(keep) }, reveal: { loot.reveal(keep) })
                }
            }
            .padding(HoardList.inset)

            Divider().overlay(Palette.hairline).padding(.horizontal, HoardList.edge)
            VStack(spacing: 1) {
                Foot("Open Downloads Folder") {
                    hoard.openAt = nil
                    NSWorkspace.shared.open(browser.currentDownloadFolder)
                }
                Foot("All Downloads", keys: Keymap.shared.keys(.downloads)?.text) {
                    hoard.openAt = nil
                    browser.openPlace(.downloads)
                }
            }
            .padding(HoardList.inset)
        }
        .frame(width: Tray.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Two lines and an icon, forty points tall: the extensions list's
    /// choice rows.
    private struct Line<Icon: View, End: View>: View {
        let title: String
        let detail: String
        var alarm = false
        @ViewBuilder let icon: () -> Icon
        @ViewBuilder let end: (_ hovering: Bool) -> End
        var act: (() -> Void)?
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                icon().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(alarm ? Color.red.opacity(0.8) : Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                end(hovering)
            }
            .padding(.leading, HoardList.rowSide)
            .padding(.trailing, Tool.inset)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: HoardList.inner, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture { act?() }
            .onHover { hovering = $0 }
        }
    }

    private struct FetchRow: View {
        @ObservedObject var hoard: Hoard
        /// The numbers, watched here and only here: the list is the one
        /// thing that needs them ten times a second, and only while it is open.
        @ObservedObject var meter: Hoard.Meter
        let fetch: Hoard.Fetch

        private var step: Hoard.Step { self.meter.steps[fetch.id] ?? Hoard.Step() }

        var body: some View {
            Line(title: fetch.name, detail: fetch.paused ? "Paused" : fetch.failed ? "Couldn't download" : said,
                 alarm: fetch.failed && !fetch.paused) {
                HoardRowDial(fraction: step.fraction, failed: fetch.failed, unknown: step.fraction == nil && step.got > 0,
                             side: 20, tone: hoard.browser?.chorus.tone)
                    .opacity(hoard.carrying && hoard.fetches.first?.id == fetch.id ? 0 : 1)
                    .modifier(HoardRowSpot(hoard: hoard, on: hoard.fetches.first?.id == fetch.id, inset: 1, side: 20))
            } end: { _ in
                HStack(spacing: 2) {
                    if fetch.failed {
                        Tool(symbol: "arrow.clockwise", help: fetch.paused ? "Resume" : "Try Again") { hoard.retry(fetch) }
                    }
                    Tool(symbol: "xmark", help: fetch.failed ? "Remove" : "Cancel") {
                        fetch.failed ? hoard.dismiss(fetch) : hoard.cancel(fetch)
                    }
                }
            } act: {
                if fetch.failed { hoard.retry(fetch) }
            }
        }

        private var said: String { HoardList.said(fetch, step: step) }
    }

    private struct KeptRow: View {
        @ObservedObject var hoard: Hoard
        /// The list's first row: nothing is going above it.
        var first = false
        let keep: Keep
        let open: () -> Void
        let reveal: () -> Void

        /// A file saved a moment ago is "just now", not "in 0s": the clock
        /// it was stamped with and this one can be a hair apart.
        private var when: String {
            abs(keep.date.timeIntervalSinceNow) < 10 ? "just now" : When.said(keep.date)
        }

        var body: some View {
            let there = keep.stillThere
            Line(title: keep.name, detail: there ? (keep.from.isEmpty ? when : "\(IDN.shown(keep.from)) · \(when)") : "Moved or deleted") {
                Thumb(keep: keep, side: 20)
                    .opacity(there ? 1 : 0.4)
                    .opacity(first && hoard.carrying ? 0 : 1)
                    .modifier(HoardFileGrows(keep: keep, hoard: hoard))
                    .modifier(HoardRowSpot(hoard: hoard, on: first, inset: 1, side: 20))
            } end: { hovering in
                if hovering, there {
                    Tool(symbol: "magnifyingglass", help: "Show in Finder", act: reveal)
                }
            } act: {
                if there { open() }
            }
        }
    }

    /// The extensions list's foot rows, with the shortcut at the far end.
    private struct Foot: View {
        let title: String
        var keys: String?
        let act: () -> Void
        @State private var hovering = false

        init(_ title: String, keys: String? = nil, act: @escaping () -> Void) {
            self.title = title
            self.keys = keys
            self.act = act
        }

        var body: some View {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                if let keys {
                    KeyGlyphs(keys: keys, size: 12.5)
                }
            }
            .padding(.horizontal, HoardList.rowSide)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: HoardList.inner, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
        }
    }

    /// A small icon button at the end of a row, inset from its edge and
    /// rounded to match it, the extensions list's.
    private struct Tool: View {
        static let inset: CGFloat = 4
        let symbol: String
        let help: String
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                Symbol(symbol, size: 22 * 0.48, weight: .medium)
                    .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: HoardList.inner - Tool.inset, style: .continuous).fill(hovering ? Palette.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .keyTip(help)
        }
    }

    /// The Finder's icon for a kind of file, asked for once per kind: the
    /// list is drawn again with every step of a download while it is open.
    private static var icons: [String: NSImage] = [:]

    private static let bytes: ByteCountFormatter = {
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        return bytes
    }()

    /// How far a download has got, in words: "144 MB of 452 MB · 13 min".
    static func said(_ fetch: Hoard.Fetch, step: Hoard.Step) -> String {
        let bytes = Self.bytes
        guard step.total > 0 else {
            guard step.got > 0 else { return fetch.from.isEmpty ? "Starting…" : IDN.shown(fetch.from) }
            // No size to go by: what has come, and how fast on average.
            let elapsed = Date().timeIntervalSince(fetch.started)
            guard elapsed >= 1 else { return bytes.string(fromByteCount: step.got) }
            return "\(bytes.string(fromByteCount: step.got)) · \(bytes.string(fromByteCount: Int64(Double(step.got) / elapsed)))/s"
        }
        var line = "\(bytes.string(fromByteCount: step.got)) of \(bytes.string(fromByteCount: step.total))"
        if let fraction = step.fraction, fraction > 0.05, fraction < 1 {
            let left = Date().timeIntervalSince(fetch.started) * (1 - fraction) / fraction
            line += left < 60 ? " · \(max(1, Int(left))) s" : " · \(Int(left / 60)) min"
        }
        return line
    }

    static func icon(named name: String) -> NSImage {
        let kind = (name as NSString).pathExtension.lowercased()
        if let icon = icons[kind] { return icon }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: kind) ?? .data)
        icons[kind] = icon
        return icon
    }
}
