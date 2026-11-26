import AppKit
import CoreVideo
import CoreImage
import IOSurface
import WebKit

/// The last frame of each page that was on screen, kept so that going back
/// to its tab shows that page at once, in the frame the switch is drawn in,
/// whatever WebKit is doing (docs/page-snapshots.md).
///
/// A page coming back into the window has nothing to show until its web
/// content process has painted it again: a frame or two when it is idle,
/// a second or more when its scripts are busy. Until then the stage kept
/// the page just left in its place, another tab's page. Now it shows this
/// page's own last frame (a still), and the live page takes its place on
/// the first frame WebKit has drawn.
///
/// A still is pictured by the page's own process (`takeSnapshot`) when the
/// page leaves the stage and when it settles while on it, drawn off the
/// main thread into an IOSurface that the render server shows without a
/// copy, and kept in this app's memory only: private tabs' stills never
/// reach the disk, nobody's do. It is used only while everything it was
/// drawn for still holds (`Key`): the same address, size, scale, zoom,
/// appearance and scroll. Anything else and the page comes in as before.
@MainActor
final class PageStills {
    static let shared = PageStills()

    /// Off only for measuring what stills change (`stills` bench verb, or
    /// the `stills` setting "off" in a test world).
    static var on = !(Store.testing && Store.settings.string(forKey: "stills") == "off") && !LinkGap.cut("stills")

    /// What a still was drawn for. Shown only for exactly this.
    struct Key: Equatable {
        var url: URL?
        /// Points, the stage's: the page is shown at its stage's size.
        var size: CGSize
        var scale: CGFloat
        var zoom: CGFloat
        var magnification: CGFloat
        var dark: Bool
        /// Where the page was scrolled to, as it last said (`PageView.scrollTop`).
        var y: Double

        /// Why a still drawn for `self` can't stand in for a page now at
        /// `now`, or nil when it can.
        func refusal(for now: Key) -> String? {
            if url != now.url { return "address" }
            if abs(size.width - now.size.width) > 0.5 || abs(size.height - now.size.height) > 0.5 { return "size" }
            if scale != now.scale { return "scale" }
            if abs(zoom - now.zoom) > 0.001 || abs(magnification - now.magnification) > 0.001 { return "zoom" }
            if dark != now.dark { return "appearance" }
            if abs(y - now.y) > 1 { return "scroll" }
            return nil
        }

        /// The same for a page being built again in its place (a closed tab
        /// brought back): it has no address nor scroll of its own yet, so
        /// only where and how it is shown count.
        func looseRefusal(for now: Key) -> String? {
            if abs(size.width - now.size.width) > 0.5 || abs(size.height - now.size.height) > 0.5 { return "size" }
            if scale != now.scale { return "scale" }
            if dark != now.dark { return "appearance" }
            return nil
        }
    }

    final class Still {
        let owner: UUID
        let key: Key
        fileprivate(set) var surface: IOSurface
        /// Drawn at half the page's pixels: a still not looked at lately.
        fileprivate(set) var reduced: Bool
        let shy: Bool
        /// When it was drawn or last shown, for which goes first.
        fileprivate(set) var used: CFTimeInterval
        /// On a stage now: never made volatile, never dropped from under it.
        fileprivate(set) var showing = 0
        /// When the page was pictured.
        let drawn = CACurrentMediaTime()
        /// Being halved off the main thread: its surface is read there.
        fileprivate var halving = false

        fileprivate init(owner: UUID, key: Key, surface: IOSurface, reduced: Bool, shy: Bool) {
            self.owner = owner
            self.key = key
            self.surface = surface
            self.reduced = reduced
            self.shy = shy
            used = CACurrentMediaTime()
        }

        var bytes: Int { surface.allocationSize }
        var pixels: CGSize { CGSize(width: surface.width, height: surface.height) }
    }

    private var stills: [UUID: Still] = [:]
    /// Owners whose still stands for a page built again in its place
    /// (`rehome(loose:)`), matched by `Key.looseRefusal`.
    private var loose: Set<UUID> = []
    /// Monotonic nonzero epoch per owner: a picture asked for before `forget`
    /// is dropped on arrival, and entries for closed/forgotten owners with no
    /// in-flight capture can be pruned safely since 0 never matches.
    private var epochs: [UUID: Int] = [:]
    private var inFlight: [UUID: Int] = [:]
    private var epochClock = 0
    /// Shared immutable CIContext: avoids recreating Metal context state on
    /// every thumbnail or tile picture.
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])

    private func nextEpoch() -> Int {
        epochClock &+= 1
        if epochClock == Int.min || epochClock == 0 { epochClock = 1 }
        return epochClock
    }

    private func currentEpoch(for owner: UUID) -> Int {
        if let existing = epochs[owner] { return existing }
        let made = nextEpoch()
        epochs[owner] = made
        return made
    }

    private func endCapture(for owner: UUID) {
        let remaining = (inFlight[owner] ?? 1) - 1
        inFlight[owner] = remaining > 0 ? remaining : nil
        if remaining <= 0, stills[owner] == nil, asked[owner] == nil {
            epochs[owner] = nil
        }
    }
    /// Pictures asked for and not yet back, by owner.
    private var asked: [UUID: CFTimeInterval] = [:]
    /// The tabs a switch is likely to go to next: the space on screen and
    /// the pages in front of the spaces beside it (`near`). Theirs are kept
    /// whole; everyone else's are halved.
    private var near: Set<UUID> = []
    private var pressure: DispatchSourceMemoryPressure?
    private var appearance: NSObjectProtocol?
    private let queue = DispatchQueue(label: "page stills", qos: .userInitiated)

    /// How many bytes of stills are kept at most: a share of the Mac's
    /// memory, between 48 and 256 MB. A whole still of a page on a Retina
    /// screen is 16 to 30 MB; a halved one a quarter of that.
    static let budget: Int = {
        if Store.testing, let mb = Store.settings.object(forKey: "stills.mb") as? Int, mb > 0 { return mb << 20 }
        return budget(memory: ProcessInfo.processInfo.physicalMemory)
    }()

    nonisolated static func budget(memory: UInt64) -> Int {
        Int(min(256 << 20, max(48 << 20, memory / 96)))
    }

    /// How many of the most recently used are kept whole whatever space
    /// they are in: going back and forth between two or three tabs.
    static let whole = 3

    // MARK: - what the bench reads

    private(set) var hits = 0
    private(set) var misses: [String: Int] = [:]
    private(set) var captures = 0
    private(set) var failed = 0
    /// Chromium stills made from the page's last whole picture, not asked for.
    private(set) var reused = 0
    private(set) var captureMs: [Double] = []
    /// The main thread's own share of each picture: asking, and taking the
    /// answer (WebKit's own handling of its reply comes before it).
    private(set) var mainMs: [Double] = []

    var report: [String: Any] {
        [
            "on": PageStills.on,
            "count": stills.count,
            "bytes": stills.values.reduce(0) { $0 + $1.bytes },
            "budget": PageStills.budget,
            "reduced": stills.values.filter(\.reduced).count,
            "hits": hits, "misses": misses, "captures": captures, "failed": failed, "reused": reused,
            "capture_ms": captureMs.suffix(40).map { ($0 * 10).rounded() / 10 },
            "main_ms": mainMs.suffix(80).map { ($0 * 100).rounded() / 100 },
            "near": near.count,
            "owners": stills.values.sorted { $0.used > $1.used }.map {
                ["id": String($0.owner.uuidString.prefix(8)).lowercased(), "mb": Double($0.bytes) / 1_048_576,
                 "reduced": $0.reduced, "w": $0.pixels.width, "h": $0.pixels.height, "showing": $0.showing]
            },
        ]
    }

    func resetCounts() {
        hits = 0
        misses = [:]
        captures = 0
        failed = 0
        reused = 0
        captureMs = []
        mainMs = []
    }

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.pressure?.data else { return }
                self.relieve(critical: event.contains(.critical))
            }
        }
        source.resume()
        pressure = source
        // Fonts and sizes of Settings › Appearance lay every page out anew.
        appearance = NotificationCenter.default.addObserver(forName: PageAppearance.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forgetAll() }
        }
    }

    // MARK: - asking for one

    /// The still of `owner`'s page if it was drawn for exactly `key`, made
    /// ready to show; nil, with the reason counted, otherwise.
    func still(for owner: UUID, matching key: Key) -> Still? {
        guard PageStills.on else { return nil }
        guard let still = stills[owner] else {
            misses["none", default: 0] += 1
            return nil
        }
        if let why = loose.contains(owner) ? still.key.looseRefusal(for: key) : still.key.refusal(for: key) {
            misses[why, default: 0] += 1
            drop(owner)
            return nil
        }
        // Kept volatile while unseen: the kernel may have taken it back.
        guard still.showing > 0 || keep(still.surface) else {
            misses["purged", default: 0] += 1
            drop(owner)
            return nil
        }
        hits += 1
        still.used = CACurrentMediaTime()
        return still
    }

    /// Whether `still(for:matching:)` would most likely give one, without
    /// counting or dropping anything.
    func has(_ owner: UUID, matching key: Key) -> Bool {
        guard PageStills.on, let still = stills[owner] else { return false }
        return still.key.refusal(for: key) == nil
    }

    /// On a stage, and off it again.
    func shown(_ still: Still) {
        still.showing += 1
    }

    func hidden(_ still: Still) {
        still.showing = max(0, still.showing - 1)
        guard still.showing == 0 else { return }
        // A frame or two later: the render server may still be drawing it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak still] in
            guard let self, let still, still.showing == 0, !still.halving, self.stills[still.owner] === still else { return }
            self.firm()
        }
    }

    // MARK: - drawing one

    /// The page as it is now, pictured by its own process and kept for
    /// `owner`, for exactly `key`. One picture at a time a page; a page that
    /// doesn't answer within a few seconds is let be.
    func take(_ web: WKWebView, owner: UUID, key: Key, shy: Bool) {
        guard PageStills.on, key.size.width >= 32, key.size.height >= 32, key.scale > 0 else { return }
        let now = CACurrentMediaTime()
        if let since = asked[owner], now - since < 4 { return }
        // Pictured a moment ago for the same: going back and forth between
        // two tabs pictures each once, not on every switch.
        if let kept = stills[owner], kept.key.refusal(for: key) == nil, now - kept.drawn < 2 { return }
        asked[owner] = now
        let epoch = currentEpoch(for: owner)
        inFlight[owner, default: 0] += 1
        let configuration = WKSnapshotConfiguration()
        // What it shows now: a page leaving the window draws no more.
        configuration.afterScreenUpdates = false
        let asking = CACurrentMediaTime()
        web.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let heard = CACurrentMediaTime()
                defer { self.mainMs.append((CACurrentMediaTime() - heard) * 1000) }
                guard self.epochs[owner, default: 0] == epoch else {
                    self.endCapture(for: owner)
                    self.failed += 1
                    return
                }
                self.asked[owner] = nil
                // WebKit's own bitmap, never redrawn here (NSImage.cgImage
                // would draw it again on this thread).
                guard let image, let rep = image.representations.first,
                      let picture = rep.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    self.endCapture(for: owner)
                    self.failed += 1
                    return
                }
                let pixels = CGSize(width: (key.size.width * key.scale).rounded(), height: (key.size.height * key.scale).rounded())
                self.queue.async {
                    let surface = PageStills.surface(from: picture, pixels: pixels)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            defer { self.endCapture(for: owner) }
                            guard let surface, self.epochs[owner, default: 0] == epoch else {
                                self.failed += 1
                                return
                            }
                            self.captures += 1
                            self.captureMs.append((CACurrentMediaTime() - now) * 1000)
                            if self.captureMs.count > 200 { self.captureMs.removeFirst(100) }
                            self.store(Still(owner: owner, key: key, surface: surface, reduced: false, shy: shy))
                        }
                    }
                }
            }
        }
        mainMs.append((CACurrentMediaTime() - asking) * 1000)
        if mainMs.count > 200 { mainMs.removeFirst(100) }
    }

    /// Chromium supplies its own pixels through the page seam. Cache them
    /// under the same viewport/scroll/appearance key as a WebKit still.
    func take(_ page: ChromiumPage, owner: UUID, key: Key, shy: Bool) {
        guard Self.on, key.size.width >= 32, key.size.height >= 32, key.scale > 0 else { return }
        let revision = page.navigationTab?.engineNavigationRevision
        func matches() -> Bool {
            page.navigationTab?.gone == false && page.navigationTab?.builtPage === page &&
                page.navigationTab?.engineNavigationRevision == revision && page.url == key.url && page.bounds.size == key.size && page.pageZoom == key.zoom &&
                page.magnification == key.magnification && abs((page.navigationTab?.lastY ?? 0) - key.y) <= 1
        }
        guard matches() else { return }
        let now = CACurrentMediaTime()
        if let since = asked[owner], now - since < 4 { return }
        // A whole page's picture from the renderer each time, and a still only
        // stands in for the 10-15 ms until the page's own frame: leaving a tab
        // again with the same view of the same page takes no new one.
        if let kept = stills[owner], kept.key.refusal(for: key) == nil, now - kept.drawn < 30 { return }
        asked[owner] = now
        let epoch = currentEpoch(for: owner)
        inFlight[owner, default: 0] += 1
        let pixels = CGSize(width: (key.size.width * key.scale).rounded(), height: (key.size.height * key.scale).rounded())
        // The page was just pictured whole as it is now, for the tone's look
        // after the scroll that brought this still (ChromiumPage.RecentWhole):
        // that picture, rather than the window drawn and read back again.
        if let encoded = page.recentWholePicture() {
            let size = key.size, scale = key.scale
            queue.async {
                let picture = ChromiumPage.picture(encoded, page: size, rect: CGRect(origin: .zero, size: size), width: size.width, backing: scale)?
                    .cgImage(forProposedRect: nil, context: nil, hints: nil)
                let surface = picture.flatMap { Self.surface(from: $0, pixels: pixels) }
                DispatchQueue.main.async {
                    defer { self.endCapture(for: owner) }
                    guard self.epochs[owner, default: 0] == epoch else { return }
                    self.asked[owner] = nil
                    guard let surface, matches() else { self.failed += 1; return }
                    self.captures += 1
                    self.reused += 1
                    self.captureMs.append((CACurrentMediaTime() - now) * 1000)
                    if self.captureMs.count > 200 { self.captureMs.removeFirst(100) }
                    self.store(Still(owner: owner, key: key, surface: surface, reduced: false, shy: shy))
                }
            }
            return
        }
        // Asked now, ahead of the page's hide (the stage calls this before the
        // page leaves it): Chromium pictures a page only while it is shown.
        page.snapshotInOrder(PageShot(afterUpdates: false, brief: true)) { [weak self] image, _ in
            guard let self else { return }
            guard self.epochs[owner, default: 0] == epoch, matches() else {
                self.endCapture(for: owner)
                return
            }
            self.asked[owner] = nil
            guard let picture = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.endCapture(for: owner)
                self.failed += 1
                return
            }
            self.queue.async {
                let surface = Self.surface(from: picture, pixels: pixels)
                DispatchQueue.main.async {
                    defer { self.endCapture(for: owner) }
                    guard let surface, self.epochs[owner, default: 0] == epoch, matches() else { return }
                    self.captures += 1
                    self.captureMs.append((CACurrentMediaTime() - now) * 1000)
                    if self.captureMs.count > 200 { self.captureMs.removeFirst(100) }
                    self.store(Still(owner: owner, key: key, surface: surface, reduced: false, shy: shy))
                }
            }
        }
    }

    /// `owner`'s still kept under `to` instead: a page left for another, its
    /// last frame kept for its place in the tab's history (Tab.itemStills).
    /// Only a still of the page as it was last shown (`now`, its address
    /// aside): one drawn before a scroll it didn't catch up with is dropped.
    func move(_ owner: UUID, to: UUID, like now: Key) {
        guard PageStills.on, let still = stills[owner] else { return }
        var now = now
        now.url = still.key.url
        guard still.key.refusal(for: now) == nil else { return }
        stills[owner] = nil
        stills[to] = Still(owner: to, key: still.key, surface: still.surface, reduced: still.reduced, shy: still.shy)
        fit()
    }

    /// `owner`'s still kept under `to`, drawn for what `key` makes of its
    /// own: a closed tab's last frame kept for ⇧⌘T, and given to the tab
    /// that brings it back (Browser.remember, Browser.reopen).
    func rehome(_ owner: UUID, to: UUID, loose: Bool = false) {
        guard PageStills.on, let still = stills[owner] else { return }
        stills[owner] = nil
        self.loose.remove(owner)
        if loose { self.loose.insert(to) }
        stills[to] = Still(owner: to, key: still.key, surface: still.surface, reduced: still.reduced, shy: still.shy)
        fit()
    }

    /// `owner`'s still as a picture of its own, its pixels copied out of
    /// the surface (which may be taken back once it is unseen), at the
    /// page's size in points.
    func picture(of owner: UUID) -> NSImage? {
        guard PageStills.on, let still = stills[owner], still.showing > 0 || keep(still.surface) else { return nil }
        let image = CIImage(ioSurface: still.surface)
        guard let copy = PageStills.context.createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: copy, size: still.key.size)
    }

    /// The same, small, drawn off the main thread: ⌃Tab asks for every tile
    /// at once, and a still of a whole 5K window takes tens of milliseconds.
    func picture(of owner: UUID, width: CGFloat, done: @escaping @MainActor (NSImage?) -> Void) {
        guard PageStills.on, let still = stills[owner], still.showing > 0 || keep(still.surface) else { return done(nil) }
        let surface = still.surface, size = still.key.size
        DispatchQueue.global(qos: .userInitiated).async {
            let source = CIImage(ioSurface: surface)
            let scale = min(1, 2 * width / max(source.extent.width, 1))
            let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let copy = PageStills.context.createCGImage(image, from: image.extent)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(copy.map { NSImage(cgImage: $0, size: size) }) }
            }
        }
    }

    /// The still kept under `owner`, whatever page it is now asked for:
    /// the caller has matched it (a history entry's address and size).
    func kept(_ owner: UUID) -> Still? {
        guard PageStills.on, let still = stills[owner] else { return nil }
        guard still.showing > 0 || keep(still.surface) else {
            drop(owner)
            return nil
        }
        still.used = CACurrentMediaTime()
        return still
    }

    private func store(_ still: Still) {
        stills[still.owner] = still
        loose.remove(still.owner)
        fit()
    }

    // MARK: - letting go

    /// The page went somewhere else, slept or closed: its still is no
    /// longer it, and a picture still on its way is not either.
    func forget(_ owner: UUID) {
        epochs[owner] = nil
        asked[owner] = nil
        drop(owner)
    }

    func forgetAll() {
        for owner in Set(stills.keys).union(epochs.keys).union(asked.keys) { forget(owner) }
    }

    private func drop(_ owner: UUID) {
        stills[owner] = nil
        loose.remove(owner)
        if asked[owner] == nil, inFlight[owner, default: 0] == 0 { epochs[owner] = nil }
    }

    /// The tabs a switch is likely to go to next (`Browser.stillsNear`).
    func keepNear(_ owners: Set<UUID>) {
        near = owners
        fit()
    }

    /// Memory short: everything but the few most recent goes; out, all of it.
    func relieve(critical: Bool) {
        let order = stills.values.sorted { $0.used > $1.used }
        for (index, still) in order.enumerated() where still.showing == 0 && (critical || index >= 2) {
            drop(still.owner)
        }
        fit()
    }

    /// Within the budget: the most recent and the near ones whole, the
    /// rest halved, the oldest dropped.
    private func fit() {
        let plan = PageStills.plan(stills.values.map {
            Entry(owner: $0.owner, used: $0.used, bytes: $0.bytes, reduced: $0.reduced, near: near.contains($0.owner), showing: $0.showing > 0)
        }, budget: PageStills.budget, whole: PageStills.whole)
        for owner in plan.drop { drop(owner) }
        for owner in plan.reduce { reduce(owner) }
        firm()
    }

    /// The most recently used stills stay out of the kernel's reach, up to
    /// half the budget and at least two; only the older ones are volatile.
    /// Volatile memory is the first the kernel takes back whenever it needs
    /// pages, not only when memory is short: on adhd with every still
    /// volatile but two, a tab left four switches before had lost its still
    /// in half the takes. Our own memory pressure source drops the whole
    /// ones when memory really is short (`relieve`).
    static let kept = 2

    /// The most recent made whole within half the budget, every other still
    /// not on a stage volatile; one the kernel took back meanwhile goes.
    private func firm() {
        var held = 0
        for (index, still) in stills.values.sorted(by: { $0.used > $1.used }).enumerated()
            where still.showing == 0 && !still.halving {
            if index < PageStills.kept || held + still.bytes <= PageStills.budget / 2 {
                held += still.bytes
                if !keep(still.surface) { drop(still.owner) }
            } else {
                loosen(still.surface)
            }
        }
    }

    struct Entry: Equatable {
        var owner: UUID
        var used: CFTimeInterval
        var bytes: Int
        var reduced: Bool
        var near: Bool
        var showing: Bool
    }

    /// Which stills to halve and which to drop: the `whole` most recent,
    /// the near ones and any on a stage stay as they are; the others are
    /// halved (a quarter of the bytes); then, oldest first, stills go until
    /// what is left is within the budget. On a stage is never dropped.
    nonisolated static func plan(_ entries: [Entry], budget: Int, whole: Int) -> (reduce: [UUID], drop: [UUID]) {
        let order = entries.sorted { $0.used > $1.used }
        var reduce: [UUID] = []
        var sizes: [UUID: Int] = [:]
        for (index, entry) in order.enumerated() {
            let keepWhole = index < whole || entry.near || entry.showing
            if !keepWhole, !entry.reduced {
                reduce.append(entry.owner)
                sizes[entry.owner] = entry.bytes / 4
            } else {
                sizes[entry.owner] = entry.bytes
            }
        }
        var total = sizes.values.reduce(0, +)
        var drop: [UUID] = []
        for entry in order.reversed() where total > budget && !entry.showing {
            drop.append(entry.owner)
            total -= sizes[entry.owner] ?? 0
        }
        return (reduce.filter { !drop.contains($0) }, drop)
    }

    private func reduce(_ owner: UUID) {
        guard let still = stills[owner], !still.reduced, still.showing == 0 else { return }
        // Marked now, so a second fit doesn't halve it again while this runs.
        still.reduced = true
        guard keep(still.surface) else {
            drop(owner)
            return
        }
        let source = still.surface
        still.halving = true
        let pixels = CGSize(width: max(1, (still.pixels.width / 2).rounded()), height: max(1, (still.pixels.height / 2).rounded()))
        queue.async {
            let half = PageStills.halve(source, to: pixels)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    still.halving = false
                    guard let half, self.stills[owner] === still, still.showing == 0 else {
                        // Shown meanwhile, or not halved: still whole.
                        still.reduced = false
                        if self.stills[owner] === still, still.showing == 0 { self.loosen(source) }
                        return
                    }
                    still.surface = half
                    self.firm()
                }
            }
        }
    }

    // MARK: - surfaces

    /// kIOSurfacePurgeable…: Swift names their cases differently from one
    /// SDK to the next.
    nonisolated static let nonVolatile = IOSurfacePurgeabilityState(rawValue: 0)
    nonisolated static let volatile = IOSurfacePurgeabilityState(rawValue: 1)
    nonisolated static let empty = IOSurfacePurgeabilityState(rawValue: 2)

    /// Volatile while unseen: the kernel may take it back under pressure
    /// rather than squeeze pages for it, and it doesn't count against the
    /// app's footprint meanwhile.
    private func loosen(_ surface: IOSurface) {
        _ = surface.setPurgeable(PageStills.volatile, oldState: nil)
    }

    /// Made whole again for showing; false when the kernel had taken it.
    private func keep(_ surface: IOSurface) -> Bool {
        var old = PageStills.nonVolatile
        _ = surface.setPurgeable(PageStills.nonVolatile, oldState: &old)
        return old != PageStills.empty
    }

    nonisolated private static func make(_ pixels: CGSize) -> IOSurface? {
        let width = Int(pixels.width), height = Int(pixels.height)
        guard width > 0, height > 0 else { return nil }
        let row = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
        return IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4, .bytesPerRow: row,
            .allocSize: row * height, .pixelFormat: kCVPixelFormatType_32BGRA,
        ])
    }

    /// The color space the screen shows a page in. WebKit hands back its
    /// pictures in extended range, half floats; drawn into 8 bits here.
    nonisolated private static func space(of picture: CGImage) -> CGColorSpace {
        if let space = picture.colorSpace, space.model == .rgb, !CGColorSpaceUsesExtendedRange(space),
           space.name != CGColorSpace.linearSRGB, space.name != CGColorSpace.extendedLinearSRGB {
            return space
        }
        return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    }

    nonisolated static func surface(from picture: CGImage, pixels: CGSize) -> IOSurface? {
        // What WebKit drew, at the size asked for; scaled to fit if it
        // drew at another scale.
        guard let surface = make(pixels) else { return nil }
        let space = space(of: picture)
        draw(into: surface, space: space) { context, rect in
            context.interpolationQuality = .medium
            context.draw(picture, in: rect)
        }
        return surface
    }

    nonisolated static func halve(_ source: IOSurface, to pixels: CGSize) -> IOSurface? {
        guard let surface = make(pixels) else { return nil }
        _ = source.lock(options: .readOnly, seed: nil)
        defer { _ = source.unlock(options: .readOnly, seed: nil) }
        let space = surfaceSpace(source)
        guard let provider = CGDataProvider(dataInfo: nil, data: source.baseAddress,
                                            size: source.bytesPerRow * source.height, releaseData: { _, _, _ in }),
              let image = CGImage(width: source.width, height: source.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: source.bytesPerRow, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        draw(into: surface, space: space) { context, rect in
            context.interpolationQuality = .medium
            context.draw(image, in: rect)
        }
        return surface
    }

    nonisolated private static let spaceKey = "IOSurfaceColorSpace" as CFString

    nonisolated private static func surfaceSpace(_ surface: IOSurface) -> CGColorSpace {
        if let list = IOSurfaceCopyValue(surface, spaceKey), let space = CGColorSpace(propertyListPlist: list as CFPropertyList) { return space }
        return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    }

    nonisolated private static func draw(into surface: IOSurface, space: CGColorSpace, _ body: (CGContext, CGRect) -> Void) {
        _ = surface.lock(options: [], seed: nil)
        defer { _ = surface.unlock(options: [], seed: nil) }
        guard let context = CGContext(
            data: surface.baseAddress, width: surface.width, height: surface.height, bitsPerComponent: 8,
            bytesPerRow: surface.bytesPerRow, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        let rect = CGRect(x: 0, y: 0, width: surface.width, height: surface.height)
        // Opaque under the page: a page with no ground of its own is white.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        body(context, rect)
        // Tagged, so the render server shows it in the colors it was drawn in.
        if let list = space.copyPropertyList() { IOSurfaceSetValue(surface, spaceKey, list) }
    }
}

extension PageStills {
    /// What a page on `stage` would be shown for now, from the page's own
    /// state and the stage it is (or will be) on.
    static func key(_ page: ChromiumPage, on stage: NSView) -> Key {
        Key(url: page.url, size: stage.bounds.size, scale: stage.window?.backingScaleFactor ?? 2,
            zoom: page.pageZoom, magnification: page.magnification,
            dark: stage.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
            y: page.navigationTab?.lastY ?? 0)
    }

    static func key(_ web: WKWebView, on stage: NSView) -> Key {
        let dark = stage.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return Key(url: web.url, size: stage.bounds.size,
                   scale: stage.window?.backingScaleFactor ?? 2,
                   zoom: web.pageZoom, magnification: web.magnification, dark: dark,
                   y: (web as? PageView)?.scrollTop ?? 0)
    }
}

extension Browser {
    /// `coming`'s page on screen at once from its last frame, on the stage
    /// the page in front has now, called by a pick or a change of space
    /// before anything of the switch is written: the flush then commits the
    /// still alone, where after the writes AppKit's display cycle would run
    /// SwiftUI's whole pass for the switch inside it (StageView.early).
    /// Nothing happens without a still for exactly that stage, or with a
    /// pair on screen or coming.
    @discardableResult
    func showEarly(_ coming: Tab) -> Bool {
        guard PageStills.on else { return false }
        let shown = StageView.early(from: active, to: coming,
                        single: stagePair == nil && !splitBook.frozen && stages.compactMap { $0 }.count == 1 && pair(of: coming.id) == nil)
        // Which stills to keep whole, once the switch is done.
        let comingID = coming.id
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            PageStills.shared.keepNear(self.stillsNear(focusing: comingID))
        }
        return shown
    }

    /// The tabs a switch is likely to go to next: the active/coming tab,
    /// its immediate neighbors in the row, the few most recently used tabs,
    /// and the page left in front of each space either side of this one.
    /// Older tabs in a large space halve to a quarter of the memory so more
    /// tabs stay cached instead of being evicted.
    var stillsNear: Set<Tab.ID> { stillsNear(focusing: activeID) }

    func stillsNear(focusing focused: Tab.ID?) -> Set<Tab.ID> {
        var near = Set(recentlyUsed())
        let visible = tabs.map(\.id)
        if let focused, visible.contains(focused) { near.insert(focused) }
        if let activeID { near.insert(activeID) }
        if let index = focused.flatMap(visible.firstIndex(of:)) ?? activeID.flatMap(visible.firstIndex(of:)) {
            let low = max(0, index - 2)
            let high = min(visible.count - 1, index + 2)
            if low <= high {
                for id in visible[low...high] { near.insert(id) }
            }
        }
        let order = turnOrder.map(\.id)
        if let here = order.firstIndex(of: spaceID), order.count > 1 {
            for step in [-1, 1] {
                let id = order[(here + step + order.count) % order.count]
                if let active = parked[id]?.active { near.insert(active) }
            }
        }
        return near
    }
}
