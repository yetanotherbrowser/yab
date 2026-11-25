import Foundation
import Network
import XCTest
@testable import YabPhone

/// Which files the system may fetch again, the request it sends, and the
/// session's delegate path with real URLSession transfers from an owned
/// local listener. The session here is an ordinary one hardened the same
/// way: a unit test can't be woken by iOS, so the background identifier, the
/// relaunch and the app delegate's handler are the system's part.
@MainActor
final class BackgroundDownloadsTests: XCTestCase {
    private var root: URL!
    private var site: BackgroundSite!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-background-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        site = try BackgroundSite()
        try await site.start()
    }

    override func tearDown() async throws {
        site?.stop(); site = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - which files go

    private func get(_ url: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpBody = body
        return request
    }

    private func answer(_ url: String, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
    }

    func testOnlyAWholeReplayableGetGoesToTheSystem() {
        let page = "https://acme.com/file.zip", served = "https://cdn.acme.com/file.zip"
        XCTAssertEqual(BackgroundTransfer.eligibleURL(original: get(page), response: answer(served), isPrivate: false),
                       URL(string: served), "the URL that served the file, after redirects")
        XCTAssertNil(BackgroundTransfer.eligibleURL(original: get(page), response: answer(served), isPrivate: true), "private stays in WebKit")
        XCTAssertNil(BackgroundTransfer.eligibleURL(original: get(page, method: "POST"), response: answer(served), isPrivate: false))
        XCTAssertNil(BackgroundTransfer.eligibleURL(original: get(page, body: Data("a=1".utf8)), response: answer(served), isPrivate: false))
        XCTAssertNil(BackgroundTransfer.eligibleURL(original: get(page), response: answer(served, status: 206), isPrivate: false))
        XCTAssertNil(BackgroundTransfer.eligibleURL(original: get("blob:https://acme.com/1"), response: answer(served), isPrivate: false))
        XCTAssertNil(BackgroundTransfer.eligibleURL(original: get("data:text/plain,hi"), response: nil, isPrivate: false))
        XCTAssertNil(BackgroundTransfer.eligibleURL(original: nil, response: answer(served), isPrivate: false))
        let plain = URLResponse(url: URL(string: served)!, mimeType: nil, expectedContentLength: 1, textEncodingName: nil)
        XCTAssertNil(BackgroundTransfer.eligibleURL(original: get(page), response: plain, isPrivate: false))
    }

    private func cookie(_ name: String, domain: String, path: String = "/", secure: Bool = false,
                        expires: Date? = nil, strict: Bool = false) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "1", .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        if strict { properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue }
        return HTTPCookie(properties: properties)!
    }

    func testTheRequestCarriesOnlyTheCookiesABrowserWouldSendThere() throws {
        let now = Date()
        let jar = [
            cookie("host", domain: "files.acme.com"),
            cookie("parent", domain: ".acme.com"),
            cookie("sibling", domain: "www.acme.com"),
            cookie("other", domain: ".other.com"),
            cookie("lookalike", domain: ".cme.com"),
            cookie("path", domain: ".acme.com", path: "/files"),
            cookie("elsewhere", domain: ".acme.com", path: "/filesystem"),
            cookie("wrongpath", domain: ".acme.com", path: "/private"),
            cookie("secure", domain: ".acme.com", secure: true),
            cookie("expired", domain: ".acme.com", expires: now.addingTimeInterval(-60)),
            cookie("strict", domain: ".acme.com", strict: true),
        ]
        let url = URL(string: "https://files.acme.com/files/report.zip")!
        var original = get("https://acme.com/report")
        original.setValue("YabTest/1", forHTTPHeaderField: "User-Agent")
        original.setValue("https://acme.com/", forHTTPHeaderField: "Referer")
        original.setValue("Basic secret", forHTTPHeaderField: "Authorization")
        original.setValue("leak", forHTTPHeaderField: "X-Page-Header")
        original.setValue("jar=all", forHTTPHeaderField: "Cookie")

        let scoped = BackgroundTransfer.cookies(jar, for: url, page: "acme.com", now: now)
        XCTAssertEqual(Set(scoped.map(\.name)), ["host", "parent", "path", "secure", "strict"])
        XCTAssertNil(BackgroundTransfer.request(for: url, original: nil, page: "acme.com", cookies: jar, now: now),
                     "cookies must remain in WebKit: a background redirect could forward them")
        XCTAssertNil(BackgroundTransfer.request(for: url, original: original, page: nil, cookies: []),
                     "Authorization and Cookie headers must not leave WebKit")
        original.setValue(nil, forHTTPHeaderField: "Cookie")
        XCTAssertNil(BackgroundTransfer.request(for: url, original: original, page: nil, cookies: []))
        original.setValue(nil, forHTTPHeaderField: "Authorization")
        let anonymous = try XCTUnwrap(BackgroundTransfer.request(for: URL(string: "https://nobody.net/x")!, original: original,
                                                                 page: nil, cookies: jar, now: now))
        XCTAssertEqual(anonymous.httpMethod, "GET")
        XCTAssertFalse(anonymous.httpShouldHandleCookies)
        XCTAssertEqual(anonymous.value(forHTTPHeaderField: "User-Agent"), "YabTest/1")
        XCTAssertNil(anonymous.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(anonymous.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(anonymous.value(forHTTPHeaderField: "X-Page-Header"))
        XCTAssertNil(anonymous.value(forHTTPHeaderField: "Referer"))
    }

    func testOnlyTheFileCountsAndOnlyStopIsThePersons() {
        XCTAssertTrue(BackgroundTransfer.delivered(answer("https://a.com/x")))
        XCTAssertFalse(BackgroundTransfer.delivered(answer("https://a.com/x", status: 404)))
        XCTAssertFalse(BackgroundTransfer.delivered(answer("https://a.com/x", status: 500)))
        XCTAssertFalse(BackgroundTransfer.delivered(answer("https://a.com/x", status: 206)))
        XCTAssertFalse(BackgroundTransfer.delivered(nil))
        XCTAssertTrue(BackgroundTransfer.stoppedByPerson(URLError(.cancelled)))
        let swiped = URLError(.cancelled, userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: NSURLErrorCancelledReasonUserForceQuitApplication])
        XCTAssertFalse(BackgroundTransfer.stoppedByPerson(swiped), "the system's cancel keeps Retry")
        XCTAssertFalse(BackgroundTransfer.stoppedByPerson(URLError(.timedOut)))
        XCTAssertFalse(BackgroundTransfer.stoppedByPerson(nil))
    }

    // MARK: - the session

    private final class Events {
        var begun: [UUID] = []
        var acceptsFiles = true
        var progress: [UUID: Int64] = [:]
        var finished: [UUID: (name: String, bytes: Data)] = [:]
        var failed: [UUID: (@MainActor () -> Void)?] = [:]
        var dropped: [UUID] = []
        var stops: [UUID: @MainActor () -> Void] = [:]
    }

    private var ledger: URL { root.appendingPathComponent("ledger.json") }

    private func service(_ events: Events) -> BackgroundDownloads {
        let configuration = URLSessionConfiguration.ephemeral
        BackgroundDownloads.harden(configuration)
        let sink = BackgroundDownloads.Sink(
            begin: { record, stop in events.begun.append(record.id); events.stops[record.id] = stop },
            progress: { id, received, _ in events.progress[id] = received },
            finish: { record, file in
                guard events.acceptsFiles, let bytes = try? Data(contentsOf: file) else { return false }
                events.finished[record.id] = (record.name, bytes)
                return true
            },
            fail: { record, retry in events.failed[record.id] = retry },
            drop: { id in events.dropped.append(id) })
        return BackgroundDownloads(configuration: configuration, ledger: ledger,
                                   staging: root.appendingPathComponent("staging", isDirectory: true), sink: sink)
    }

    private func savedRecords() -> [BackgroundTransfer.Record] {
        (try? JSONDecoder().decode([BackgroundTransfer.Record].self, from: Data(contentsOf: ledger))) ?? []
    }

    private func stagingIsEmpty() -> Bool {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty
    }

    private func until(_ check: () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            if check() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if !check() { XCTFail(message, file: file, line: line); throw URLError(.timedOut) }
    }

    func testAWholeFileLandsUnderItsRowWithoutCookiesAndLeavesNothingBehind() async throws {
        let events = Events(), downloads = service(events), id = UUID()
        let url = site.url("/file")
        let request = try XCTUnwrap(BackgroundTransfer.request(for: url, original: nil, page: "127.0.0.1",
                                                 cookies: [cookie("other", domain: ".other.com")]))
        downloads.start(request, record: .init(id: id, name: "Owned.txt", host: "127.0.0.1", total: Int64(BackgroundSite.bytes.count)))
        XCTAssertEqual(events.begun, [id], "the row is the transfer's at once")
        let saved = try XCTUnwrap(savedRecords().first)
        XCTAssertEqual(saved.id, id)
        XCTAssertEqual(saved.name, "Owned.txt")
        let ledgerText = String(decoding: try Data(contentsOf: ledger), as: UTF8.self)
        XCTAssertFalse(ledgerText.contains("session"), "no cookie on Yab's disk")
        XCTAssertFalse(ledgerText.contains("127.0.0.1:"), "no URL on Yab's disk")

        try await until({ events.finished[id] != nil }, "the whole file never reached the sink")
        XCTAssertEqual(events.finished[id]?.bytes, BackgroundSite.bytes)
        XCTAssertEqual(events.finished[id]?.name, "Owned.txt")
        XCTAssertTrue(events.failed.isEmpty)
        XCTAssertTrue(savedRecords().isEmpty, "a finished task leaves the ledger")
        XCTAssertTrue(downloads.running.isEmpty)
        XCTAssertTrue(stagingIsEmpty())
        let header = try XCTUnwrap(site.requests.last)
        XCTAssertFalse(header.lowercased().contains("\r\ncookie:"), header)
        XCTAssertFalse(header.contains("other=1"))
    }

    func testAnErrorPageIsAFailureWithRetryAndRetryLandsUnderTheSameRow() async throws {
        let events = Events(), downloads = service(events), id = UUID()
        downloads.start(URLRequest(url: site.url("/flaky")), record: .init(id: id, name: "Flaky.txt", host: "127.0.0.1", total: nil))
        try await until({ events.failed[id] != nil }, "a 404 body was not a failure")
        XCTAssertNil(events.finished[id], "an error page never reaches Downloads")
        XCTAssertTrue(stagingIsEmpty())
        XCTAssertTrue(savedRecords().isEmpty)
        let retry = try XCTUnwrap(events.failed[id] ?? nil)
        site.healFlaky()
        retry()
        XCTAssertEqual(events.begun, [id, id])
        try await until({ events.finished[id] != nil }, "Retry never landed")
        XCTAssertEqual(events.finished[id]?.bytes, BackgroundSite.bytes)
        XCTAssertTrue(savedRecords().isEmpty)
    }

    func testStopDropsTheRowAndKeepsNothing() async throws {
        let events = Events(), downloads = service(events), id = UUID()
        downloads.start(URLRequest(url: site.url("/hold")), record: .init(id: id, name: "Held.bin", host: "127.0.0.1", total: 1_000))
        try await until({ (events.progress[id] ?? 0) > 0 }, "the held transfer never began")
        let stop = try XCTUnwrap(events.stops[id])
        stop()
        try await until({ events.dropped == [id] }, "Stop never dropped the row")
        XCTAssertTrue(events.failed.isEmpty)
        XCTAssertNil(events.finished[id])
        XCTAssertTrue(savedRecords().isEmpty)
        XCTAssertTrue(downloads.running.isEmpty)
        XCTAssertTrue(stagingIsEmpty())
    }

    func testRedirectedAnonymousTransferCarriesNoCredentials() async throws {
        let events = Events(), downloads = service(events), id = UUID()
        var original = URLRequest(url: site.url("/source"))
        original.setValue("https://private.example/path", forHTTPHeaderField: "Referer")
        let request = try XCTUnwrap(BackgroundTransfer.request(for: site.url("/redirect"), original: original,
                                                              page: "127.0.0.1", cookies: []))
        downloads.start(request, record: .init(id: id, name: "Redirected.txt", host: "127.0.0.1", total: nil))
        try await until({ events.finished[id] != nil }, "redirected file never arrived")
        XCTAssertEqual(events.finished[id]?.bytes, BackgroundSite.bytes)
        let header = try XCTUnwrap(site.requests.last).lowercased()
        XCTAssertTrue(header.contains("\r\nhost: localhost:"), "the file came from a different host")
        XCTAssertFalse(header.contains("\r\ncookie:"))
        XCTAssertFalse(header.contains("\r\nauthorization:"))
        XCTAssertFalse(header.contains("\r\nreferer:"))
    }

    func testFailedFileMoveKeepsRetry() async throws {
        let events = Events(), downloads = service(events), id = UUID()
        events.acceptsFiles = false
        downloads.start(URLRequest(url: site.url("/file")), record: .init(id: id, name: "File.txt", host: "127.0.0.1", total: nil))
        try await until({ events.failed[id] != nil }, "a failed move did not offer Retry")
        XCTAssertTrue(downloads.running.isEmpty)
        XCTAssertTrue(stagingIsEmpty())
        events.acceptsFiles = true
        let retry = try XCTUnwrap(events.failed[id] ?? nil)
        retry()
        try await until({ events.finished[id] != nil }, "Retry after a failed move never landed")
        XCTAssertEqual(events.finished[id]?.bytes, BackgroundSite.bytes)
    }

    func testEventCompletionWorksInEitherCallbackOrder() {
        let downloads = service(Events())
        var completions = 0
        downloads.finishedEvents()
        downloads.whenEventsFinish { completions += 1 }
        XCTAssertEqual(completions, 1)
        downloads.whenEventsFinish { completions += 1 }
        XCTAssertEqual(completions, 1)
        downloads.finishedEvents()
        XCTAssertEqual(completions, 2)
    }

    func testMissingSystemTaskLeavesAFailedRowAndNoStaleLedger() async throws {
        let record = BackgroundTransfer.Record(id: UUID(), name: "Lost.txt", host: "127.0.0.1", total: 10, task: 999)
        try JSONEncoder().encode([record]).write(to: ledger)
        let events = Events(), downloads = service(events)
        downloads.reattach()
        try await until({ events.failed[record.id] != nil }, "the missing task was never reconciled")
        XCTAssertNil(events.failed[record.id] ?? nil, "there is no request to retry")
        XCTAssertTrue(savedRecords().isEmpty)
    }

    func testARecordOutlivesTheProcessThatStartedIt() async throws {
        let events = Events(), first = service(events), id = UUID()
        first.start(URLRequest(url: site.url("/hold")), record: .init(id: id, name: "Held.bin", host: "127.0.0.1", total: 1_000))
        let again = service(Events())
        XCTAssertEqual(again.record(id)?.name, "Held.bin", "a relaunch finds the row's facts")
        XCTAssertEqual(again.record(id)?.total, 1_000)
        XCTAssertNotNil(again.record(id)?.task)
        first.stop(id)
        try await until({ events.dropped == [id] }, "Stop never dropped the row")
    }
}

/// An owned HTTP listener: /file is the file, /flaky a 404 until healed,
/// /hold a file whose last bytes never come.
private final class BackgroundSite: @unchecked Sendable {
    static let bytes = Data("Owned background download café+tea\n".utf8)
    private let listener: NWListener
    private let queue = DispatchQueue(label: "owned.background.site")
    private var connections: [NWConnection] = []
    private var received: [String] = []
    private var healed = false
    var requests: [String] { queue.sync { received } }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")! }
    func healFlaky() { queue.sync { healed = true } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async {
                var waiting: CheckedContinuation<Void, Error>? = done
                self.listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: waiting?.resume(); waiting = nil
                    case let .failed(error): waiting?.resume(throwing: error); waiting = nil
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { connection in
                    self.connections.append(connection)
                    connection.start(queue: self.queue)
                    self.receive(connection, Data())
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func stop() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() }; connections = [] } }

    private func receive(_ connection: NWConnection, _ previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, ended, error in
            var bytes = previous
            if let chunk { bytes.append(chunk) }
            guard error == nil, let header = String(data: bytes, encoding: .utf8), header.contains("\r\n\r\n") else {
                if ended || error != nil { connection.cancel() } else { self.receive(connection, bytes) }
                return
            }
            self.received.append(header)
            let target = header.components(separatedBy: " ").dropFirst().first ?? "/"
            let body = Self.bytes
            func head(_ status: String, _ length: Int) -> Data {
                Data("HTTP/1.1 \(status)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n".utf8)
            }
            switch target {
            case "/redirect":
                let address = "http://localhost:\(self.listener.port!.rawValue)/file"
                self.send(Data("HTTP/1.1 302 Found\r\nLocation: \(address)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), connection)
            case "/hold":
                connection.send(content: head("200 OK", 1_000) + body, completion: .contentProcessed { _ in })
            case "/flaky" where !self.healed:
                let page = Data("<h1>Not found</h1>".utf8)
                self.send(head("404 Not Found", page.count) + page, connection)
            default:
                self.send(head("200 OK", body.count) + body, connection)
            }
        }
    }

    private func send(_ data: Data, _ connection: NWConnection) {
        connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
