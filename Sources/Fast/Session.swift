import Foundation

// What was open last time. A list of addresses and their names, and which one
// you were looking at, nothing else, because everything else is either on the
// page or in the history file next door.

enum Session {
    struct Entry: Codable {
        var url: String
        var title: String
        var pin: String?
        /// What you called the tab yourself, if anything. Missing from
        /// sessions written before a tab could be named.
        var name: String?
        /// When it was last looked at, in seconds since 1970, so a tab left
        /// alone overnight is still known to have been, after a relaunch.
        /// Missing from sessions written before it was kept.
        var seen: Double?
        /// Kept above the line (Kept.swift), and the folder of yours it is
        /// in: the folder's id, its name and whether it was open, on each of
        /// its tabs, there being no list of folders apart from them.
        var kept: Bool? = nil
        var folder: String? = nil
        var folderName: String? = nil
        var folderOpen: Bool? = nil
        /// The folders that folder is in, from the top down (Nest.path), on
        /// each of its tabs too; missing for one at the top of the kept, and
        /// from sessions written before a folder could be in another.
        var folderPath: [Step]? = nil
        /// For a search's folder, among today's tabs: the words searched.
        var folderSearch: String? = nil
        /// For a folder you made of today's tabs, among them (Nest.fleeting).
        var folderToday: Bool? = nil
        var folderOrdinaryToday: Bool? = nil
        /// For one a ⌘-click or a ⌥⇧-click made (Nest.linked): its mark is
        /// its site's, or its emoji. Missing from sessions written before.
        var folderLinked: Bool? = nil
        /// A live folder's source, on each of its tabs, and a tab it
        /// brought, what it is (Live.swift).
        var folderLive: Live? = nil
        var live: LiveMark? = nil
        var customMark: String? = nil
        var folderMark: String? = nil
        var folderColor: String? = nil
        /// How many times it has been on screen (Tab.visits), so a tab you
        /// keep coming back to stays awake after a relaunch too.
        var visits: Int? = nil
        /// The tab's own id, the same after a relaunch, which is what sync
        /// knows it by (PLAN-sync.md). Missing from sessions written before.
        var id: String? = nil
        /// How far down the page it was read (Tab.depth).
        var depth: Double? = nil
        /// A pin's or a kept tab's home, the address it was pinned or kept
        /// at, and that page's title (PinnedHome.swift). Missing from
        /// sessions written before: the address it is at.
        var home: String? = nil
        var homeTitle: String? = nil
        /// In a window other than the first: a kept tab or a pin of the
        /// space as every window has it (KeptEverywhere.swift), its id the
        /// list's, read again from the list rather than from here. Missing
        /// from a window's own, and from sessions written before.
        var shared: Bool? = nil
        /// Missing in older sessions means WebKit. Unknown future names are
        /// retained as text and resolve to WebKit in this version.
        var engine: String? = nil
        var engineKind: PageEngineKind { engine.flatMap(PageEngineKind.init(rawValue:)) ?? .webKit }
        /// The engine this entry's tab comes back on.
        @MainActor var restoredEngine: PageEngineKind {
            EngineRules.restored(saved: engineKind, url: URL(string: url), standard: PageEngineFactory.requestedEngine)
        }
    }

    /// Two tabs side by side, by where each stands in `tabs`.
    struct Pair: Codable {
        var first: Int
        var second: Int
        var share: Double
        /// A third and fourth pane, how they are laid and where the other
        /// dividers stand (Split.swift). Missing from sessions written
        /// before; a Yab from before reads the first two, a pair.
        var more: [Int]? = nil
        var arrangement: String? = nil
        var cuts: [Double]? = nil

        /// The same pair with its tabs in new places: nil when either of the
        /// first two has none.
        func moved(_ place: (Int) -> Int?) -> Pair? {
            guard let a = place(first), let b = place(second), a != b else { return nil }
            var next = self
            next.first = a
            next.second = b
            if let more {
                let placed = more.compactMap(place)
                // A pane gone takes the others' places with it: laid evenly
                // again, as a split a pane left is.
                if placed.count != more.count { next.cuts = nil; next.share = 0.5 }
                next.more = placed.isEmpty ? nil : placed
                if placed.isEmpty, next.arrangement == "grid" { next.arrangement = nil }
            }
            return next
        }
    }

    struct Shape: Codable {
        var tabs: [Entry]
        var active: Int
        /// Missing from sessions written before two tabs could share the
        /// window.
        var pairs: [Pair]? = nil
        /// Left with no tab in front, the field over the page: it comes back
        /// so, as a space does in Arc, never on its first pin or folder tab.
        /// `active` is 0 beside it, which is all a Yab from before reads.
        /// Missing from a row left on a tab, and from sessions written before.
        var nothingInFront: Bool? = nil
    }

    /// Whether a tab at this address is written down: a web page, or a page
    /// on this Mac, as a start page of your own pinned (feedback #214),
    /// which Arc keeps and syncs as it is. Never about:blank, a data: or
    /// one of Yab's own pages.
    static func writes(_ url: URL) -> Bool {
        url.scheme?.hasPrefix("http") == true || url.isFileURL
    }

    /// The first space's is the session there always was; another space's
    /// is a file of its own beside it (Spaces.swift).
    private static func file(_ space: UUID?, window: UUID? = nil) -> URL {
        if let window {
            let suffix = space.flatMap { $0 == Space.firstID ? nil : "-\($0.uuidString)" } ?? ""
            return Store.file("session-window-\(window.uuidString)\(suffix).json")
        }
        guard let space, space != Space.firstID else { return Store.file("session.json") }
        return Store.file("session-\(space.uuidString).json")
    }

    /// The row as last written: a row written a moment ago reads back as
    /// written, from memory while its write is still queued, without
    /// waiting for it, and from the disk once it has landed.
    static func read(space: UUID? = nil, window: UUID? = nil) -> Shape {
        MainBudget.chunk("session.read") {
            let file = file(space, window: window)
            if let queued = queued(file) { return queued }
            return readFile(file)
        }
    }

    /// The last shape asked to be written to each file whose write has not
    /// landed yet, and how many of its writes are still queued.
    private static let pendingLock = NSLock()
    private static var pending: [URL: (shape: Shape, count: Int)] = [:]

    private static func queued(_ file: URL) -> Shape? {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return pending[file]?.shape
    }

    private static func asked(_ file: URL, _ shape: Shape) {
        pendingLock.lock(); defer { pendingLock.unlock() }
        pending[file] = (shape, (pending[file]?.count ?? 0) + 1)
    }

    private static func landed(_ file: URL) {
        pendingLock.lock(); defer { pendingLock.unlock() }
        guard let entry = pending[file] else { return }
        pending[file] = entry.count > 1 ? (entry.shape, entry.count - 1) : nil
    }

    private static func readFile(_ file: URL) -> Shape {
        // No row yet, a new space's or one an import is filling: none in
        // front, so what is put in it is not woken for it either.
        guard let data = try? Data(contentsOf: file) else { return Shape(tabs: [], front: nil) }
        guard let shape = try? JSONDecoder().decode(Shape.self, from: data) else {
            // A file that's there but won't decode is not the same as no
            // file: something wrote it, and overwriting it on the next save
            // without a trace is how yesterday's tabs actually disappear.
            Store.quarantine(file)
            return Shape(tabs: [], front: nil)
        }
        return shape
    }

    /// Every write goes through this queue, one after another, so a later
    /// one never lands under an earlier one. On the main thread a write is
    /// queued and the thread goes on: encoding a row of 150 tabs and the
    /// atomic write are no work for the window. Reads wait for what is
    /// queued (`read`, `settle`). Quitting doesn't wait for a background
    /// queue, and a session handed to one on the way out may never reach
    /// the disk, so what is written inside `land` (the way out) is on disk
    /// before it returns, with everything queued before it.
    private static let writes = DispatchQueue(label: "yab.session", qos: .utility)

    /// Inside `land`: writes asked for with `now` wait for the disk.
    /// Touched on the main thread only.
    private static var landing = 0

    /// Every write asked for so far, on disk.
    static func settle() {
        writes.sync {}
    }

    /// `work`, its writes on disk before this returns, as a quit or a
    /// closing window needs them, and every write queued before them.
    static func land(_ work: () -> Void) {
        landing += 1
        defer {
            landing -= 1
            settle()
        }
        work()
    }

    /// Whether a write asked for `now` from this thread waits for the disk:
    /// on the way out, or off the main thread, where waiting holds up no
    /// window and the caller may be about to exit.
    static func waits(now: Bool, main: Bool, landing: Int) -> Bool {
        now && (landing > 0 || !main)
    }

    /// Posted on the main thread after the first window's row of a space is
    /// on disk, the space as the object: what sync listens for.
    static let written = Notification.Name("yab.session.written")

    static func write(now: Bool = false, space: UUID? = nil, window: UUID? = nil, _ shape: Shape) {
        let file = Session.file(space, window: window)
        asked(file, shape)
        let put = { MainBudget.chunk("session.write") {
            defer { landed(file) }
            guard let data = try? JSONEncoder().encode(shape) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
            if window == nil {
                DispatchQueue.main.async { NotificationCenter.default.post(name: written, object: space ?? Space.firstID) }
            }
        } }
        // One after another, in the order they were asked for: a later write
        // never lands under an earlier one, however long each takes. `now`
        // means no debounce; it waits for the disk only on the way out.
        if waits(now: now, main: Thread.isMainThread, landing: landing) {
            writes.sync(execute: put)
        } else {
            writes.async(execute: put)
        }
    }

    /// A deleted space's, gone with it.
    /// In the queue with the writes: one still queued for the space lands
    /// before it, not after, over a space already gone.
    static func erase(space: UUID) {
        guard space != Space.firstID else { return }
        let row = file(space), folder = Store.folder
        writes.sync {
            try? FileManager.default.removeItem(at: row)
            if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix("session-window-")
                    && file.lastPathComponent.hasSuffix("-\(space.uuidString).json") {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}

extension Session.Shape {
    /// A row with `front` in front, its place in `tabs`, below zero for one
    /// of the shared pins (SharedPins.swift), nil for none at all.
    init(tabs: [Session.Entry], front: Int?, pairs: [Session.Pair]? = nil) {
        self.init(tabs: tabs, active: front ?? 0, pairs: pairs, nothingInFront: front == nil ? true : nil)
    }

    /// The place of the tab in front, below zero for a shared pin, nil when
    /// the row was left with none.
    var front: Int? { nothingInFront == true ? nil : active }
}

extension Session.Pair {
    /// Written for this pair, by where each tab stands: nil when either
    /// of the first two isn't there; a pane past them that isn't is
    /// left out.
    init?(_ pair: Fast.Pair, at place: (Tab.ID) -> Int?) {
        guard let a = place(pair.first), let b = place(pair.second) else { return nil }
        self.init(first: a, second: b, share: Double(pair.share))
        let more = pair.more.compactMap(place)
        guard !pair.halves else { return }
        if !more.isEmpty { self.more = more }
        arrangement = pair.arrangement.rawValue
        // A pane left out leaves the dividers to be laid evenly again.
        if !pair.cuts.isEmpty, more.count == pair.more.count { cuts = pair.cuts.map(Double.init) }
    }
}
