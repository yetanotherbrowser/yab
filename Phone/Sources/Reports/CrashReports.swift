import Foundation
import UIKit

// When Yab for iPhone quits unexpectedly, iOS keeps a report of it and hands
// it to Yab at the next launch (MetricKit, DiagnosticsWatcher). The reports
// it hasn't sent yet can go to the site, so the same crash on many iPhones
// can be found and fixed: what goes is DiagnosticReports'.
//
// Off until you say, as on the Mac. When there are new reports, Yab asks to
// send them. Declining skips those reports; a later crash asks again.
// Automatic sending is a separate switch in Settings › About. Only a build
// that has a site sends anything (Reports.site), and only reports of crashes
// after the first launch that could send them, never a backlog from before.
//
// A hang of 2 s or more (DiagnosticReports.hangReportMs) is a report too,
// under the same yes: it never asks on its own. It goes with automatic
// sending on, or under the yes the next crash's question gets, which covers
// every report waiting.
//
// With the first report that goes, what was kept for one: the stacks of
// the newest shorter hangs (HangStacks), iOS's daily counts of how Yab
// ended (ExitCounts), and the main thread's update loops (UpdateLoops),
// then those are forgotten.

/// The reports waiting, those you said yes to among them, and the keys of
/// every one already looked at: a crash iOS hands over again is not asked
/// about twice, and one you said yes to that the site didn't take goes
/// later without asking again.
struct CrashLedger: Codable, Equatable, Sendable {
    var pending: [CrashReport] = []
    var allowed: [String] = []
    var seen: [String] = []

    /// Crashes waiting at most, newest kept.
    static let pendingKept = 5
    /// Hangs waiting at most, apart, so they never push a crash out.
    static let hangsKept = 3
    static let seenKept = 200

    /// The new ones among `reports`: waiting, and seen from now on.
    mutating func add(_ reports: [CrashReport]) {
        let fresh = unseen(reports)
        let all = pending + fresh
        let kept = Set(all.filter { !$0.isHang }.suffix(Self.pendingKept).map(\.key)
            + all.filter(\.isHang).suffix(Self.hangsKept).map(\.key))
        pending = all.filter { kept.contains($0.key) }
        remember(fresh)
    }

    /// Seen, and never asked about: the first launch's backlog.
    mutating func pass(_ reports: [CrashReport]) {
        remember(unseen(reports))
    }

    mutating func remove(_ keys: Set<String>) {
        pending.removeAll { keys.contains($0.key) }
        allowed.removeAll { keys.contains($0) }
    }

    mutating func allow(_ keys: Set<String>) {
        allowed = pending.map(\.key).filter { keys.contains($0) || allowed.contains($0) }
    }

    /// Waiting and not yet asked about.
    var unasked: [CrashReport] { pending.filter { !allowed.contains($0.key) } }

    private func unseen(_ reports: [CrashReport]) -> [CrashReport] {
        var known = Set(seen)
        return reports.filter { known.insert($0.key).inserted }
    }

    private mutating func remember(_ reports: [CrashReport]) {
        seen = Array((seen + reports.map(\.key)).suffix(Self.seenKept))
    }
}

@MainActor
final class CrashReports {
    static let shared = CrashReports(defaults: .standard, folder: CrashReports.defaultFolder)

    /// Automatic sending (Settings › About), off unless turned on.
    nonisolated static let key = "crash.send"
    /// The first launch that could send: what arrives in it is from before.
    nonisolated static let sinceKey = "crash.since"

    /// The outcome of asking: an answer, or not asked now (Yab was in the
    /// back, the welcome or something else was up): asked again later.
    typealias Ask = @MainActor () async -> Bool?
    /// One report's fields to the site; true once the site took it.
    typealias Post = @MainActor ([String: Any]) async -> Bool

    let defaults: UserDefaults
    let folder: URL
    var ask: Ask
    var post: Post?
    /// The question is up: another offer waits for its answer.
    private(set) var asking = false
    private var sending = false
    /// This launch is the first that could send.
    private(set) var backlog = false

    init(defaults: UserDefaults, folder: URL, ask: @escaping Ask = { await CrashQuestion.ask() }, post: Post? = nil) {
        self.defaults = defaults
        self.folder = folder
        self.ask = ask
        self.post = post
    }

    static var defaultFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Reports", isDirectory: true)
    }

    var ledgerFile: URL { folder.appendingPathComponent("crashes.json") }
    var hangFile: URL { folder.appendingPathComponent("hang-stacks.json") }
    var exitFile: URL { folder.appendingPathComponent("exits.json") }
    var loopFile: URL { folder.appendingPathComponent("update-loops.json") }

    var automatic: Bool { defaults.object(forKey: Self.key) as? Bool ?? false }

    /// For a build that has a site: where reports go, and whether this is
    /// the first launch that could send them.
    func start(site: URL, now: Date = Date()) {
        if post == nil { post = Self.post(to: site) }
        if defaults.object(forKey: Self.sinceKey) == nil {
            defaults.set(now, forKey: Self.sinceKey)
            backlog = true
        }
    }

    /// What MetricKit handed over: crashes and long hangs wait for a yes (or
    /// are passed over on the first launch), shorter hangs' stacks wait for
    /// a report to go with.
    func received(_ reports: [CrashReport], hangs: [[String: Any]]) async {
        HangStacks.keep(hangs, in: hangFile)
        guard !reports.isEmpty else { return }
        var ledger = load()
        if backlog { ledger.pass(reports) } else { ledger.add(reports) }
        save(ledger)
        await offer()
    }

    /// The reports waiting go now: automatically, or once you said yes.
    /// Each is asked about once. A response applies to these reports, never
    /// changes automatic sending; declined, they are dropped, so they never
    /// ask again. Only a crash asks: hangs alone wait for one.
    func offer() async {
        guard post != nil, !asking, !sending else { return }
        let unasked = load().unasked
        if !automatic, unasked.contains(where: { !$0.isHang }) {
            asking = true
            let answer = await ask()
            asking = false
            guard let answer else { return }
            var ledger = load()
            let covered = Set(unasked.map(\.key))
            if answer { ledger.allow(covered) } else { ledger.remove(covered) }
            save(ledger)
        }
        let ledger = load()
        await send(Set(automatic ? ledger.pending.map(\.key) : ledger.allowed))
    }

    /// Oldest first, as many as the site takes; one it doesn't stays for
    /// the next time Yab is in front, with those after it.
    private func send(_ keys: Set<String>) async {
        guard let post, !keys.isEmpty else { return }
        sending = true
        defer { sending = false }
        var extra = attachments()
        let hadExtra = !extra.isEmpty
        for report in load().pending where keys.contains(report.key) {
            var fields = Self.fields(report)
            fields.merge(extra) { current, _ in current }
            guard await post(fields) else { break }
            extra = [:]
            var ledger = load()
            ledger.remove([report.key])
            save(ledger)
        }
        if hadExtra, extra.isEmpty {
            HangStacks.forget(in: hangFile)
            ExitCounts.forget(in: exitFile)
            UpdateLoops.forget(in: loopFile)
        }
    }

    /// What goes with the first report: the site keeps `hangs` and `exits`
    /// inside it and `stalls` beside it (fast-web's /api/crash).
    func attachments() -> [String: Any] {
        var extra: [String: Any] = [:]
        let hangs = HangStacks.stacks(in: hangFile)
        if !hangs.isEmpty { extra["hangs"] = hangs }
        let exits = ExitCounts.days(in: exitFile)
        if !exits.isEmpty { extra["exits"] = exits }
        if let loops = UpdateLoops.stalls(in: loopFile) { extra["stalls"] = loops }
        return extra
    }

    /// What the site is sent for one report, all of it.
    static func fields(_ report: CrashReport) -> [String: Any] {
        var fields: [String: Any] = [
            "platform": DiagnosticReports.platform, "version": report.version, "build": report.build,
            "os": report.os, "device": report.device, "report": report.report, "bytes": report.report.utf8.count,
        ]
        if let exception = report.exception { fields["exception"] = exception }
        if let kind = report.kind { fields["kind"] = kind }
        return fields
    }

    // MARK: the ledger on disk

    func load() -> CrashLedger {
        guard let data = try? Data(contentsOf: ledgerFile),
              let ledger = try? JSONDecoder().decode(CrashLedger.self, from: data) else { return CrashLedger() }
        return ledger
    }

    func save(_ ledger: CrashLedger) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: ledgerFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: the site

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    static func request(site: URL, fields: [String: Any]) -> URLRequest {
        var request = URLRequest(url: site.appendingPathComponent("api/crash"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpShouldHandleCookies = false
        request.httpBody = try? JSONSerialization.data(withJSONObject: fields)
        return request
    }

    static func post(to site: URL) -> Post {
        { fields in
            guard let (_, response) = try? await session.data(for: request(site: site, fields: fields)) else { return false }
            return (response as? HTTPURLResponse)?.statusCode == 200
        }
    }
}

/// The question, in the Mac's words, as an iOS alert: Send, or Don’t Send.
@MainActor
enum CrashQuestion {
    static let title = "Share saved crash reports?"
    static let message = "iOS saved crash reports from an earlier Yab session. They include what crashed and why, the versions of Yab and iOS and the \(DeviceWord.name) model, never pages or anything you typed. Sharing them helps fix problems. You can turn on automatic sending in Settings › About."
    static let yes = "Send"
    static let no = "Don’t Send"

    /// Whatever else is up may keep it from asking now: Yab in the back,
    /// the welcome, private tabs behind their lock, or something presented.
    static var mayAsk: @MainActor () -> Bool = { true }

    static func ask() async -> Bool? {
        guard UIApplication.shared.applicationState == .active, !FirstRun.shared.started, mayAsk(),
              let presenter = presenter() else { return nil }
        return await withCheckedContinuation { continuation in
            presenter.present(alert { continuation.resume(returning: $0) }, animated: true)
        }
    }

    static func alert(_ answer: @escaping (Bool) -> Void) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: no, style: .cancel) { _ in answer(false) })
        let send = UIAlertAction(title: yes, style: .default) { _ in answer(true) }
        alert.addAction(send)
        alert.preferredAction = send
        alert.view.accessibilityIdentifier = "reports.question"
        return alert
    }

    /// The key window's root, when nothing is presented over it.
    static func presenter() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let root = windows.first(where: \.isKeyWindow)?.rootViewController, root.presentedViewController == nil
        else { return nil }
        return root
    }
}
