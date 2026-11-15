import Foundation

/// Files the system fetches for Yab while it is away or gone (#158): one
/// background URLSession, as Apple's "Downloading files in the background"
/// has it. A transfer starts in WebKit (PageDownload); when iOS is about to
/// suspend Yab with it unfinished, an eligible one (BackgroundTransfer) comes
/// here and goes on in the system's own process. When it ends, iOS wakes or
/// relaunches Yab, the session with the same identifier is made again and
/// hears what happened: the whole file is moved into DownloadStore, a failed
/// one keeps its row with Retry, a stopped one leaves nothing.
///
/// What Yab keeps of a task (BackgroundTransfer.Record) is in a small file
/// beside its data. The request itself, with the cookies scoped to it, lives
/// only in the system's task. The session keeps no cookies, credentials or
/// cache of its own, and checks certificates as the system always does.
@MainActor
final class BackgroundDownloads {
    /// Where the rows live: DownloadStore in the app (BackgroundDownloads+Store).
    struct Sink {
        /// A task is the row's, with the system's own way to stop it.
        var begin: @MainActor (BackgroundTransfer.Record, _ stop: @escaping @MainActor () -> Void) -> Void
        var progress: @MainActor (UUID, _ received: Int64, _ total: Int64?) -> Void
        /// The whole file, at a path of Yab's own: true once it is in the store.
        var finish: @MainActor (BackgroundTransfer.Record, URL) -> Bool
        var fail: @MainActor (BackgroundTransfer.Record, _ retry: (@MainActor () -> Void)?) -> Void
        /// Stopped: nothing to keep.
        var drop: @MainActor (UUID) -> Void
    }

    nonisolated static let identifier = (Bundle.main.bundleIdentifier ?? "dev.serafim.fast.iphone") + ".downloads"

    /// The system's background session, keeping nothing of the person's.
    static func configuration(identifier: String = identifier) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        harden(configuration)
        configuration.sessionSendsLaunchEvents = true
        // The person asked for it now: not when the system finds it convenient.
        configuration.isDiscretionary = false
        return configuration
    }

    /// No jar, no credentials, no cache: the request carries its own scoped
    /// cookies and nothing the server answers is kept.
    nonisolated static func harden(_ configuration: URLSessionConfiguration) {
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    }

    let sink: Sink
    private let configuration: URLSessionConfiguration
    private let ledger: URL?
    private let staging: URL
    private var session: URLSession?
    private var records: [UUID: BackgroundTransfer.Record] = [:]
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    /// Moved out of the system's hands, waiting for the task's last word.
    private var landed: [UUID: URL] = [:]
    /// The server answered with something other than the file.
    private var refused: Set<UUID> = []
    /// iOS waits on this before it takes a new picture of Yab.
    private var events: (@MainActor () -> Void)?

    /// `ledger` nil: nothing outlives the process (tests).
    init(configuration: URLSessionConfiguration, ledger: URL?, staging: URL, sink: Sink) {
        self.configuration = configuration
        self.ledger = ledger
        self.staging = staging
        self.sink = sink
        if let ledger, let data = try? Data(contentsOf: ledger),
           let saved = try? JSONDecoder().decode([BackgroundTransfer.Record].self, from: data) {
            records = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    var running: [UUID] { Array(tasks.keys) }
    func record(_ id: UUID) -> BackgroundTransfer.Record? { records[id] }

    // MARK: - the session

    /// Made at launch and when iOS has events for it: the same identifier
    /// reattaches whatever the system still holds, and hears what ended.
    func reattach() {
        let session = ensureSession()
        session.getTasksWithCompletionHandler { _, _, downloads in
            let found = downloads.map { (BackgroundTransfer.taskID($0), $0) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.adopt(found) } }
        }
    }

    /// iOS woke or launched Yab for this session: `done` once it has heard all.
    func handleEvents(_ identifier: String, done: @escaping @MainActor () -> Void) {
        guard identifier == configuration.identifier else { return }
        events = done
        reattach()
    }

    private func ensureSession() -> URLSession {
        if let session { return session }
        let made = URLSession(configuration: configuration, delegate: Relay(self), delegateQueue: nil)
        session = made
        return made
    }

    private func adopt(_ found: [(UUID?, URLSessionDownloadTask)]) {
        for (described, task) in found where task.state == .running || task.state == .suspended {
            guard let id = described ?? records.values.first(where: { $0.task == task.taskIdentifier })?.id,
                  landed[id] == nil, !refused.contains(id) else { continue }
            let record = records[id] ?? BackgroundTransfer.recovered(id, task: task)
            guard tasks[id] == nil else { continue }
            remember(record, task)
            sink.begin(record) { [weak self] in self?.stop(id) }
            let total = task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : record.total
            sink.progress(id, task.countOfBytesReceived, total)
        }
    }

    // MARK: - a transfer

    /// Hands a transfer to the system under its row (same id).
    func start(_ request: URLRequest, record: BackgroundTransfer.Record) {
        let task = ensureSession().downloadTask(with: request)
        task.taskDescription = record.id.uuidString
        if let total = record.total { task.countOfBytesClientExpectsToReceive = total }
        var record = record
        record.task = task.taskIdentifier
        refused.remove(record.id)
        remember(record, task)
        sink.begin(record) { [weak self] in self?.stop(record.id) }
        task.resume()
    }

    func stop(_ id: UUID) { tasks[id]?.cancel() }

    private func remember(_ record: BackgroundTransfer.Record, _ task: URLSessionDownloadTask) {
        records[record.id] = record
        tasks[record.id] = task
        save()
    }

    private func forget(_ id: UUID) {
        records[id] = nil
        tasks[id] = nil
        refused.remove(id)
        if let file = landed.removeValue(forKey: id) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        save()
    }

    // MARK: - what the system says

    fileprivate func wrote(_ id: UUID, received: Int64, total: Int64?) {
        guard tasks[id] != nil else { return }
        sink.progress(id, received, total ?? records[id]?.total)
    }

    /// Called on the session's queue: the system deletes `location` as soon
    /// as this returns, so the bytes are moved before that, then told.
    nonisolated fileprivate static func land(_ location: URL, response: URLResponse?, in staging: URL) -> URL? {
        guard BackgroundTransfer.delivered(response) else { return nil }
        let folder = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent("file", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: file)
            return file
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    fileprivate func landed(_ id: UUID, file: URL?, task: URLSessionTask) {
        if records[id] == nil { records[id] = BackgroundTransfer.recovered(id, task: task) }
        if let file { landed[id] = file } else { refused.insert(id) }
    }

    fileprivate func completed(_ id: UUID, task: URLSessionTask, error: Error?) {
        let record = records[id] ?? BackgroundTransfer.recovered(id, task: task)
        if let file = landed[id] {
            _ = sink.finish(record, file)
            forget(id)
            return
        }
        let wasRefused = refused.contains(id)
        let request = task.originalRequest
        forget(id)
        if !wasRefused, BackgroundTransfer.stoppedByPerson(error) { sink.drop(id); return }
        var retry: (@MainActor () -> Void)?
        if let request {
            retry = { [weak self] in self?.start(request, record: record) }
        }
        sink.fail(record, retry)
    }

    fileprivate func finishedEvents() {
        events?()
        events = nil
    }

    // MARK: - disk

    private func save() {
        guard let ledger else { return }
        let kept = records.values.sorted { $0.id.uuidString < $1.id.uuidString }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: ledger, options: .atomic)
    }

    /// The session's delegate. The session keeps it until it is invalidated,
    /// which Yab's one long-lived session never is. Its owner is set once and
    /// read only on the main thread.
    private final class Relay: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private weak var owner: BackgroundDownloads?
        private let staging: URL

        init(_ owner: BackgroundDownloads) {
            self.owner = owner
            staging = owner.staging
        }

        /// In order, on the main thread: a finish always before its task's end.
        private func main(_ work: @escaping @MainActor (BackgroundDownloads) -> Void) {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let owner = self?.owner else { return }
                    work(owner)
                }
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard let id = BackgroundTransfer.taskID(downloadTask) else { return }
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            main { $0.wrote(id, received: totalBytesWritten, total: total) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let file = BackgroundDownloads.land(location, response: downloadTask.response, in: staging)
            main { owner in
                guard let id = BackgroundTransfer.taskID(downloadTask) ?? owner.id(of: downloadTask) else {
                    if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                    return
                }
                owner.landed(id, file: file, task: downloadTask)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            main { owner in
                guard let id = BackgroundTransfer.taskID(task) ?? owner.id(of: task) else { return }
                owner.completed(id, task: task, error: error)
            }
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // The system's own trust evaluation, nothing accepted beyond it.
            completionHandler(.performDefaultHandling, nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // No stored password goes out: a site asking for one fails, and
            // Retry is the person's.
            completionHandler(.performDefaultHandling, nil)
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            main { $0.finishedEvents() }
        }
    }

    fileprivate func id(of task: URLSessionTask) -> UUID? {
        records.values.first { $0.task == task.taskIdentifier }?.id
    }
}

extension BackgroundTransfer {
    /// The row's id, which the task carries as its description.
    nonisolated static func taskID(_ task: URLSessionTask) -> UUID? { task.taskDescription.flatMap(UUID.init(uuidString:)) }
}
