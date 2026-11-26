import Foundation
import Observation

/// One file a page sent: where it came from, how large, when, and how far it
/// got. Its words are DownloadWords'.
nonisolated struct DownloadEntry: Identifiable, Equatable, Sendable, Codable {
    enum State: Equatable, Sendable, Codable {
        case running(received: Int64, total: Int64?)
        case failed
        case done
    }

    let id: UUID
    var name: String
    /// The site it came from, as Site Settings keys it.
    var host: String
    /// Bytes on disk, or what the site said it would send.
    var size: Int64
    var date: Date
    var state: State
    var isPrivate = false
    /// The file's name in its folder, once it is there: the container's path
    /// changes between launches, so the path itself is never kept.
    var file: String?

    var isRunning: Bool { if case .running = state { true } else { false } }
    var isDone: Bool { state == .done }
}

/// A site asks to send a file: what the card over the plate says.
nonisolated struct DownloadAsk: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let host: String
    /// nil: the site didn't say.
    let size: Int64?
    let isPrivate: Bool
}

/// Everything downloaded and on its way. Finished files live in
/// `Documents/Downloads`, which is the Yab folder in the Files app, and what
/// Yab knows of them (site, size, date) in an index beside the app's own data,
/// so nothing of Yab's shows in that folder. Bytes on their way stay in the
/// temporary folder and only a whole file reaches it. A private tab's file
/// stays out of all of this: out of the list and the index, in a folder of
/// its own that goes when the private tabs do.
@MainActor
@Observable
final class DownloadStore {
    /// How long the Now line says Open or Failed before it leaves.
    static let flashTime: Duration = .seconds(2)

    /// Newest first.
    private(set) var entries: [DownloadEntry] = []
    /// Sites waiting for an answer, oldest first: the card shows the first.
    private(set) var asks: [DownloadAsk] = []
    /// The last file in. The phone's Now line says it for `flashTime`; the
    /// iPad's button keeps a done file's icon until it is seen.
    private(set) var arrival: Arrival?

    /// One fact for every screen: each decides how long it shows it.
    struct Arrival: Equatable {
        let id: UUID
        /// false: it failed.
        let done: Bool
        /// The list opened, or the file did.
        var seen = false
        /// When the person could first hear of it: as it ended, or on Yab's
        /// return when it ended while away. nil while away.
        var at: Date?
        /// The Now line's moment is over.
        var said = false
    }

    struct Control {
        var stop: (@MainActor () -> Void)?
        var retry: (@MainActor () -> Void)?
    }

    private let folder: URL
    let privateFolder: URL
    private let index: URL?
    @ObservationIgnored private var controls: [UUID: Control] = [:]
    @ObservationIgnored private var answers: [UUID: @MainActor (Bool) -> Void] = [:]
    @ObservationIgnored private var lineTask: Task<Void, Never>?
    /// Yab is away: what ended is said on return, not to nobody.
    @ObservationIgnored private var away = false

    /// `index` nil: nothing outlives the app (test worlds).
    init(folder: URL, privateFolder: URL, index: URL?) {
        self.folder = folder
        self.privateFolder = privateFolder
        self.index = index
        // What private browsing left behind if Yab was killed with it open.
        try? FileManager.default.removeItem(at: privateFolder)
        if let index, let data = try? Data(contentsOf: index),
           let saved = try? JSONDecoder().decode([DownloadEntry].self, from: data) {
            entries = saved.filter { $0.isDone && !$0.isPrivate }
        }
        refresh()
    }

    /// Yab's own folders.
    static func standard() -> DownloadStore {
        let manager = FileManager.default
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DownloadStore(folder: documents.appendingPathComponent("Downloads", isDirectory: true),
                             privateFolder: manager.temporaryDirectory.appendingPathComponent("yab-private-downloads", isDirectory: true),
                             index: support.appendingPathComponent("yab-downloads.json"))
    }

    /// Folders of its own, gone with the temporary folder: tests and test worlds.
    static func temporary() -> DownloadStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-downloads-\(UUID())", isDirectory: true)
        return DownloadStore(folder: root.appendingPathComponent("Downloads", isDirectory: true),
                             privateFolder: root.appendingPathComponent("private", isDirectory: true), index: nil)
    }

    // MARK: - reading

    /// What a page sees: a private tab only private files, any other tab none.
    func list(isPrivate: Bool, host: String? = nil) -> [DownloadEntry] {
        let key = SiteSettings.key(host)
        return entries.filter { $0.isPrivate == isPrivate && (key == nil || $0.host == key) }
    }

    func entry(_ id: UUID) -> DownloadEntry? { entries.first { $0.id == id } }

    func url(of entry: DownloadEntry) -> URL? {
        guard let file = entry.file else { return nil }
        return (entry.isPrivate ? privateFolder : folder).appendingPathComponent(file, isDirectory: false)
    }

    func asking(isPrivate: Bool) -> DownloadAsk? { asks.first { $0.isPrivate == isPrivate } }

    func canStop(_ id: UUID) -> Bool { controls[id]?.stop != nil }
    func canRetry(_ id: UUID) -> Bool { controls[id]?.retry != nil }

    /// A file went from the Files app: it goes from the list too.
    func refresh() {
        let kept = entries.filter { entry in
            guard entry.isDone, !entry.isPrivate else { return true }
            return url(of: entry).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
        guard kept != entries else { return }
        entries = kept
        save()
    }

    // MARK: - the question

    func present(_ ask: DownloadAsk, answer: @escaping @MainActor (Bool) -> Void) {
        answers[ask.id] = answer
        Motion.nowGone.run { asks.append(ask) }
    }

    func answer(_ id: UUID, _ yes: Bool) {
        asks.removeAll { $0.id == id }
        answers.removeValue(forKey: id)?(yes)
    }

    /// Stopped or gone before the person said: no card about it.
    func withdraw(_ id: UUID) {
        asks.removeAll { $0.id == id }
        answers[id] = nil
    }

    // MARK: - a transfer

    /// A transfer starts, or starts again under a failed row (same `id`).
    /// A private row stays private, whatever the new transfer says.
    func begin(_ id: UUID, name: String, host: String, total: Int64?, isPrivate: Bool, control: Control) {
        controls[id] = control
        let at = entries.firstIndex(where: { $0.id == id })
        let entry = DownloadEntry(id: id, name: name, host: SiteSettings.key(host) ?? host, size: total ?? 0, date: Date(),
                                  state: .running(received: 0, total: total), isPrivate: isPrivate || at.map { entries[$0].isPrivate } == true)
        if let at { entries[at] = entry } else { entries.insert(entry, at: 0) }
        if arrival?.id == id { clearArrival() }
    }

    /// Progress, in the steps the words can show: a percent (or a quarter
    /// megabyte when the site gave no size), so a fast connection doesn't
    /// redraw the line and the list for every packet.
    func progress(_ id: UUID, received: Int64, total: Int64?) {
        guard let at = entries.firstIndex(where: { $0.id == id }),
              case let .running(before, known) = entries[at].state else { return }
        let total = total ?? known
        let old = total.flatMap { DownloadWords.percent(before, $0) }, new = total.flatMap { DownloadWords.percent(received, $0) }
        if total != nil, old == new, known == total { return }
        if total == nil, received / 262_144 == before / 262_144 { return }
        entries[at].state = .running(received: received, total: total)
        if let total { entries[at].size = total }
    }

    /// The whole file: into its folder, under a name no other file there has.
    @discardableResult
    func finish(_ id: UUID, from temporary: URL) -> Bool {
        guard let at = entries.firstIndex(where: { $0.id == id }) else { return false }
        var entry = entries[at]
        let home = entry.isPrivate ? privateFolder : folder
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let name = Self.unique(entry.name, in: home)
            try FileManager.default.moveItem(at: temporary, to: home.appendingPathComponent(name, isDirectory: false))
            entry.file = name
            entry.name = name
            let bytes = try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(name).path)[.size] as? Int64
            entry.size = bytes ?? entry.size
            entry.date = Date()
            entry.state = .done
            entries[at] = entry
            controls[id] = nil
            save()
            arrive(id, done: true)
            return true
        } catch {
            entries[at].state = .failed
            arrive(id, done: false)
            return false
        }
    }

    func fail(_ id: UUID, retry: (@MainActor () -> Void)?) {
        guard let at = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[at].state = .failed
        controls[id] = Control(stop: nil, retry: retry)
        arrive(id, done: false)
    }

    func stop(_ id: UUID) {
        guard let control = controls[id], let stop = control.stop else { return }
        stop()
    }

    func retry(_ id: UUID) {
        guard let retry = controls[id]?.retry else { return }
        retry()
    }

    /// Stopped before it finished: nothing to keep.
    func drop(_ id: UUID) {
        controls[id] = nil
        entries.removeAll { $0.id == id }
        if arrival?.id == id { clearArrival() }
        withdraw(id)
    }

    /// Delete, from the list: the file itself goes.
    func delete(_ id: UUID) {
        guard let entry = entry(id) else { return }
        if entry.isRunning { stop(id); return }
        if let url = url(of: entry) { try? FileManager.default.removeItem(at: url) }
        drop(id)
        save()
    }

    /// A new folder for a file Yab makes to hand on (a page as a PDF). A
    /// private page's is in the private folder: it goes with the private
    /// tabs, and at the next launch if Yab ended with it there.
    func exportFolder(isPrivate: Bool) -> URL {
        (isPrivate ? privateFolder : FileManager.default.temporaryDirectory)
            .appendingPathComponent("yab-pdf-\(UUID())", isDirectory: true)
    }

    /// The private tabs are gone, and with them their files.
    func forgetPrivate() {
        for entry in entries where entry.isPrivate {
            controls[entry.id]?.stop?()
            controls[entry.id] = nil
        }
        asks.filter(\.isPrivate).forEach { answer($0.id, false) }
        let gone = Set(entries.filter(\.isPrivate).map(\.id))
        entries.removeAll(where: \.isPrivate)
        if let arrival, gone.contains(arrival.id) { clearArrival() }
        try? FileManager.default.removeItem(at: privateFolder)
    }

    // MARK: - the moment after

    private func arrive(_ id: UUID, done: Bool) {
        Motion.nowGone.run { arrival = Arrival(id: id, done: done, at: away ? nil : Date()) }
        if !away { sayOnLine(id) }
    }

    /// The Now line's two seconds, from when it could be heard.
    private func sayOnLine(_ id: UUID) {
        lineTask?.cancel()
        lineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.flashTime)
            guard !Task.isCancelled, let self, self.arrival?.id == id else { return }
            Motion.nowGone.run { self.arrival?.said = true }
        }
    }

    private func clearArrival() {
        lineTask?.cancel()
        lineTask = nil
        arrival = nil
    }

    /// A downloads list opened, of a private page's files or an ordinary
    /// one's: it has shown the last file in when that file is of its kind.
    func listOpened(isPrivate: Bool) {
        guard let arrival, entry(arrival.id)?.isPrivate == isPrivate else { return }
        seen(arrival.id)
    }

    /// The file opened, or a list that shows it did: the button is itself
    /// again and the line has nothing left to say.
    func seen(_ id: UUID) {
        guard let arrival, !arrival.seen, id == arrival.id else { return }
        lineTask?.cancel()
        Motion.nowGone.run { self.arrival?.seen = true }
    }

    func leave() { away = true }

    func comeBack() {
        away = false
        refresh()
        guard let arrival, arrival.at == nil, entry(arrival.id) != nil else { return }
        Motion.nowGone.run { self.arrival?.at = Date() }
        sayOnLine(arrival.id)
    }

    // MARK: - disk

    private func save() {
        guard let index else { return }
        let kept = entries.filter { $0.isDone && !$0.isPrivate }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: index, options: .atomic)
    }

    /// `name`, or "report 2.pdf" when `folder` has one already.
    static func unique(_ name: String, in folder: URL) -> String {
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.appendingPathComponent(name).path) else { return name }
        let plain = name as NSString
        let base = plain.deletingPathExtension, ending = plain.pathExtension
        var number = 2
        while true {
            let next = ending.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ending)"
            if !manager.fileExists(atPath: folder.appendingPathComponent(next).path) { return next }
            number += 1
        }
    }

    // MARK: - test worlds

    /// A list as a named state wants it, its files real and small.
    func pretend(_ list: [DownloadEntry], arrived: UUID? = nil, stoppable: Bool = true) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: true)
        entries = list
        controls = [:]
        for entry in list {
            if let url = url(of: entry) { try? Data("Yab".utf8).write(to: url) }
            if entry.isRunning, stoppable { controls[entry.id] = Control(stop: {}, retry: nil) }
            if entry.state == .failed { controls[entry.id] = Control(stop: nil, retry: {}) }
        }
        arrival = arrived.flatMap(entry).map { Arrival(id: $0.id, done: $0.isDone, at: Date()) }
    }

    func pretend(ask: DownloadAsk) { asks = [ask] }
}

extension DownloadStore {
    /// The Now line's id: one line, however many files.
    static let nowID = "download"

    /// What goes on, in words: "report.pdf 42%", "3 files · 42%", then Open
    /// or Failed for a moment.
    func nowItem(isPrivate: Bool) -> NowItem? {
        let running = entries.filter { $0.isRunning && $0.isPrivate == isPrivate }
        if let going = DownloadWords.going(running) {
            let short = going.word.isEmpty ? (DownloadWords.overall(running).map { "\($0)%" } ?? "…") : going.word
            let mark: MacGlyph = running.count == 1 ? DownloadMark.of(running[0].name) : .yabDownload
            return NowItem(id: Self.nowID, kind: .download, title: going.title, subtitle: going.word, short: short, icon: .mac(mark))
        }
        guard let arrival, arrival.at != nil, !arrival.said, !arrival.seen,
              let entry = entry(arrival.id), entry.isPrivate == isPrivate else { return nil }
        if arrival.done {
            return NowItem(id: Self.nowID, kind: .download, title: entry.name, subtitle: "Open", short: "Open", icon: .mac(DownloadMark.of(entry.name)))
        }
        return NowItem(id: Self.nowID, kind: .download, title: entry.name, subtitle: "Failed", short: "Failed", icon: .mac(.yabDownload))
    }
}

/// A file's mark: a picture or a document.
nonisolated enum DownloadMark {
    private static let pictures: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp"]
    static func of(_ name: String) -> MacGlyph {
        pictures.contains((name as NSString).pathExtension.lowercased()) ? .photo : .doc
    }
}

/// What the line, the rows and the card say about a download, one place for
/// the words.
nonisolated enum DownloadWords {
    static func percent(_ received: Int64, _ total: Int64) -> Int? {
        guard total > 0 else { return nil }
        return min(100, Int(received * 100 / total))
    }

    /// "2.9 MB".
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "1.2 of 2.9 MB": one unit for both.
    static func of(_ received: Int64, _ total: Int64) -> String {
        let units: ByteCountFormatter.Units = total >= 1_000_000_000 ? .useGB : total >= 1_000_000 ? .useMB : .useKB
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = units
        formatter.includesUnit = false
        formatter.isAdaptive = true
        formatter.includesActualByteCount = false
        formatter.zeroPadsFractionDigits = false
        return "\(formatter.string(fromByteCount: received)) of \(size(total))"
    }

    /// The share of the whole across transfers, when each said its size.
    static func overall(_ running: [DownloadEntry]) -> Int? {
        var received: Int64 = 0, total: Int64 = 0
        for entry in running {
            guard case let .running(got, known) = entry.state, let known, known > 0 else { return nil }
            received += got
            total += known
        }
        return percent(received, total)
    }

    static func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }

    /// The Now line and the menu's row: "report.pdf 42%", "3 files · 42%";
    /// nil with nothing running.
    static func going(_ running: [DownloadEntry]) -> (title: String, word: String)? {
        guard let first = running.first else { return nil }
        if running.count > 1 {
            return (overall(running).map { "\(files(running.count)) · \($0)%" } ?? files(running.count), "")
        }
        guard case let .running(got, total) = first.state else { return nil }
        if let total, let percent = percent(got, total) { return (first.name, "\(percent)%") }
        return (first.name, got > 0 ? size(got) : "")
    }

    /// The menu's row, to the right: what is going, or how many there are.
    static func menuValue(_ list: [DownloadEntry]) -> String? {
        guard !list.isEmpty else { return nil }
        if let going = going(list.filter(\.isRunning)) {
            return going.word.isEmpty ? going.title : "\(going.title) \(going.word)"
        }
        return "\(list.count)"
    }

    /// A row's second line: "42% · 1.2 of 2.9 MB", "acme.com · 2 min ago".
    static func detail(_ entry: DownloadEntry, showsHost: Bool, now: Date, calendar: Calendar = .current) -> String {
        switch entry.state {
        case let .running(got, total):
            if let total, let percent = percent(got, total) { return "\(percent)% · \(of(got, total))" }
            return got > 0 ? size(got) : "Starting…"
        case .failed: return "Didn’t finish"
        case .done:
            let when = ago(entry.date, now: now, calendar: calendar)
            return showsHost && !entry.host.isEmpty ? "\(entry.host) · \(when)" : when
        }
    }

    /// "just now", "2 min ago", "3 hr ago", "yesterday", "Oct 9".
    static func ago(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) hr ago" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day())
    }

    /// The card's second line: "acme.com · 2.9 MB".
    static func askLine(_ ask: DownloadAsk) -> String {
        ask.size.map { $0 > 0 ? "\(ask.host) · \(size($0))" : ask.host } ?? ask.host
    }
}
