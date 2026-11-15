import UIKit
import WebKit

/// One file on its way from a page. WebKit stops at the destination until
/// the site may send it (DownloadStore's card, or a yes already given), so
/// the page stays live and nothing is written before the answer. The bytes
/// go to one owned temporary folder and only a whole file reaches the store.
/// A transfer belongs to no page: it goes on when the page navigates, its tab
/// changes or closes. Yab going to the background doesn't stop it either: a
/// background task keeps it running, and whatever it came to is said when the
/// person is back. When that time runs out with the file unfinished, a file
/// the system can fetch again as it was (BackgroundTransfer) goes on in the
/// system's background session (BackgroundDownloads) under the same row;
/// any other (private, blob:, data:, a POST) stays in WebKit for as long as
/// iOS lets it. Only the private tabs ending take a private one with them.
@MainActor
final class PageDownload: NSObject, WKDownloadDelegate {
    enum Phase { case waiting, transferring, ready, failed, cancelled }

    /// Where it came from, for the row, the question and Retry.
    struct Source {
        let tab: Tab.ID
        let host: String
        let isPrivate: Bool
    }

    let id: UUID
    let source: Source
    private(set) var phase: Phase = .waiting
    private(set) var destination: URL?
    let directory: URL
    private let download: WKDownload
    private let downloads: DownloadStore
    private let approved: Bool
    /// May the site send this? Answered at once, or by the card.
    private let ask: @MainActor (DownloadAsk, @escaping @MainActor (Bool) -> Void) -> Void
    private let retry: @MainActor (UUID, WKWebsiteDataStore?, URLRequest) -> Bool
    private let ended: @MainActor (UUID) -> Void
    /// The cookie store it read, for Retry: a page of another has other cookies.
    let store: WKWebsiteDataStore?
    private var removed = false
    private var cancelling = false
    private var progressWatch: NSKeyValueObservation?
    private var answerTaken = false
    private var destinationAnswer: (@MainActor (URL?) -> Void)?
    /// Yab is in the background: a task keeps the bytes coming.
    private(set) var away = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var noBackgroundTime = false
    /// The system's transfers, for the moment iOS ends Yab's background time.
    private let background: BackgroundDownloads?
    /// What the site answered, and the size it said: what decides a hand-off.
    private var response: URLResponse?
    private var total: Int64?
    /// The system's request, made while Yab still has time (the cookies are
    /// read from WebKit's store asynchronously), sent only when time is up.
    private(set) var prepared: URLRequest?
    /// The system took the transfer over: this one leaves the row to it.
    private(set) var handedOff = false

    /// `entry`: the failed row a Retry starts again under, already asked about.
    init(download: WKDownload, source: Source, store: DownloadStore, entry: UUID? = nil,
         ask: @escaping @MainActor (DownloadAsk, @escaping @MainActor (Bool) -> Void) -> Void,
         retry: @escaping @MainActor (UUID, WKWebsiteDataStore?, URLRequest) -> Bool, ended: @escaping @MainActor (UUID) -> Void,
         background: BackgroundDownloads? = nil) {
        id = entry ?? UUID()
        self.download = download; self.source = source; downloads = store
        approved = entry != nil
        self.ask = ask; self.retry = retry; self.ended = ended
        self.background = background
        self.store = download.webView?.configuration.websiteDataStore
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("yab-download-\(UUID())", isDirectory: true)
        super.init()
        download.delegate = self
        progressWatch = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let received = progress.completedUnitCount, total = progress.totalUnitCount
            Task { @MainActor [weak self] in
                guard let self, self.phase == .transferring, !self.cancelling else { return }
                self.downloads.progress(self.id, received: received, total: total > 0 ? total : nil)
            }
        }
    }

    /// Yab goes to the background: the transfer goes on while iOS gives it
    /// time, and the system's request is made ready for when that ends.
    func leave() {
        guard !removed, !cancelling, !away else { return }
        away = true
        guard phase == .transferring, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Download") { [weak self] in
            MainActor.assumeIsolated {
                self?.handOff()
                self?.endBackgroundTask()
            }
        }
        noBackgroundTime = backgroundTask == .invalid
        prepareHandOff()
    }

    func comeBack() {
        guard away, !removed else { return }
        away = false
        noBackgroundTime = false
        prepared = nil
        endBackgroundTask()
    }

    /// Only an anonymous file from a persistent, non-private website store.
    private func prepareHandOff() {
        guard background != nil, prepared == nil, let store, store.isPersistent,
              let url = BackgroundTransfer.eligibleURL(original: download.originalRequest, response: response,
                                                       isPrivate: source.isPrivate) else { return }
        let original = download.originalRequest, page = source.host
        store.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, self.away, self.phase == .transferring, !self.cancelling, !self.removed else { return }
            self.prepared = BackgroundTransfer.request(for: url, original: original, page: page, cookies: cookies)
            // iOS gave no time at all: hand it over now.
            if self.noBackgroundTime { self.handOff() }
        }
    }

    /// Time is up: the system starts the file again under the same row, and
    /// WebKit's writer is closed without touching it.
    func handOff() {
        guard UIApplication.shared.applicationState == .background,
              let background, let request = prepared, away, phase == .transferring, !cancelling, !removed,
              let name = destination?.lastPathComponent else { return }
        prepared = nil
        background.start(request, record: .init(id: id, name: name, host: source.host, total: total))
        handedOff = true
        cancelling = true; progressWatch = nil
        download.cancel { [self] _ in
            endBackgroundTask()
            phase = .cancelled; download.delegate = nil
            try? FileManager.default.removeItem(at: directory)
            removed = true; ended(id)
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Drop a transfer only after WebKit's cancellation completion closes its writer.
    func cancel() {
        guard !removed, !cancelling else { return }
        cancelling = true; progressWatch = nil
        downloads.withdraw(id)
        answerDestination(nil)
        if phase == .transferring || phase == .waiting {
            download.cancel { [self] _ in finishCancelled() }
        } else { finishCancelled() }
    }
    private func finishCancelled() {
        guard !removed else { return }
        endBackgroundTask()
        phase = .cancelled; download.delegate = nil
        try? FileManager.default.removeItem(at: directory)
        downloads.drop(id)
        removed = true; ended(id)
    }

    /// The transfer's turn is over, its row stays in the store.
    private func finish() {
        endBackgroundTask()
        download.delegate = nil; progressWatch = nil
        try? FileManager.default.removeItem(at: directory)
        removed = true; ended(id)
    }

    static func filename(_ suggested: String) -> String {
        let component = (suggested as NSString).lastPathComponent
        let characters = component.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" }
        let clean = String(String.UnicodeScalarView(characters)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != ".", clean != ".." else { return "Download" }
        var name = "", byteCount = 0
        // Keep whole graphemes within both the existing character limit and the
        // filesystem's 255-byte component limit. A single huge grapheme falls back.
        for character in clean.prefix(120) {
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= 255 else { break }
            name.append(character); byteCount += bytes
        }
        return name.isEmpty ? "Download" : name
    }

    private func answerDestination(_ url: URL?) {
        destinationAnswer?(url)
        destinationAnswer = nil
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard self.download === download, phase == .waiting, !cancelling, !answerTaken else { completionHandler(nil); cancel(); return }
        answerTaken = true
        destinationAnswer = completionHandler
        self.response = response
        let name = Self.filename(suggestedFilename)
        let total = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        let go: @MainActor (Bool) -> Void = { [weak self] yes in
            guard let self, !self.cancelling, !self.removed else { return }
            yes ? self.begin(name, total: total) : self.cancel()
        }
        if approved { go(true); return }
        let question = DownloadAsk(id: id, name: name, host: SiteSettings.key(source.host) ?? source.host, size: total, isPrivate: source.isPrivate)
        ask(question, go)
    }

    private func begin(_ name: String, total: Int64?) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let target = directory.appendingPathComponent(name, isDirectory: false)
            guard !FileManager.default.fileExists(atPath: target.path) else { cancel(); return }
            phase = .transferring
            destination = target
            self.total = total
            downloads.begin(id, name: name, host: source.host, total: total, isPrivate: source.isPrivate,
                        control: .init(stop: { [weak self] in self?.cancel() }, retry: nil))
            if away { away = false; leave() }
            answerDestination(target)
        } catch { showFailure() }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping @MainActor (WKDownload.RedirectPolicy) -> Void) {
        guard self.download === download, !cancelling,
              let scheme = request.url?.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            decisionHandler(.cancel); cancel(); return
        }
        decisionHandler(.allow)
    }
    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard self.download === download, !cancelling else { completionHandler(.cancelAuthenticationChallenge, nil); cancel(); return }
        // Use the native cookie/store and normal platform trust. No certificate
        // acceptance or copied credentials are introduced by the download path.
        completionHandler(.performDefaultHandling, nil)
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard self.download === download, phase == .transferring, !cancelling else { return }
        guard let destination, FileManager.default.fileExists(atPath: destination.path) else { showFailure(); return }
        let moved = downloads.finish(id, from: destination)
        phase = moved ? .ready : .failed
        Haptics.play(moved ? .success : .error, reason: moved ? Haptics.Reason.downloadReady : Haptics.Reason.downloadFailed)
        finish()
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard self.download === download, !cancelling, !removed else { return }
        showFailure()
    }
    private func showFailure() {
        guard !cancelling, !removed else { return }
        answerDestination(nil)
        downloads.withdraw(id)
        phase = .failed
        Haptics.play(.error, reason: Haptics.Reason.downloadFailed)
        // The row outlives this transfer: Retry is a new one under the same row.
        var again: (@MainActor () -> Void)?
        if let request = download.originalRequest, (request.httpMethod ?? "GET") == "GET",
           ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "") {
            let entry = id, send = retry, jar = store
            again = { _ = send(entry, jar, request) }
        }
        downloads.fail(id, retry: again)
        finish()
    }
}
