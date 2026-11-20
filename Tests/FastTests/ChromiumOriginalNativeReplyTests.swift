import Foundation
import Darwin
import Testing
@testable import YabCoreClient

// Actual owned AF_UNIX transport + production ticket/ledger tests. This server
// is NOT a CEF/native original peer and cannot admit the private native lane.
struct ChromiumOriginalNativeReplyTests {
    private func wait(_ body: () -> Bool) async throws {
        let until = Date().addingTimeInterval(4)
        while !body(), Date() < until { try await Task.sleep(nanoseconds: 2_000_000) }
        try #require(body())
    }
    @Test func olderActualWriteCannotDispatchAStillUnqueuedTicket() async throws {
        let server = try TicketWire(); defer { server.close() }
        let socket = try Socket(path: server.path); defer { socket.close() }
        socket.start()
        let payload = Data("original-target".utf8)
        let ticket = socket.prepareTracked(payload, request: "actual-target")
        socket.send(Data("older-frame".utf8))
        try await wait { server.frames.count == 1 }
        #expect(ticket.snapshot().phase == .created && ticket.snapshot().written == 0)
        socket.enqueueTracked(payload, ticket: ticket)
        try await wait { server.frames.count == 2 && ticket.snapshot().phase == .allWritten }
        #expect(server.frames == [Data("older-frame".utf8), payload])
        #expect(ticket.snapshot().written == payload.count + 1)
    }
    @Test func realTinyPartialWritesNotifyOnlyActualPhaseTransitions() async throws {
        let server = try TicketWire(); defer { server.close() }
        // Actual Darwin.write max1byte: this creates >1000 real positive partial
        // writes, not a copied counter model or manual ticket.advance injection.
        let socket = try Socket(path: server.path, maxWriteBatchBytes: 1)
        defer { socket.close() }; socket.start()
        let counter = TicketPhaseCount(), payload = Data(repeating: 120, count: 1024)
        let ticket = socket.prepareTracked(payload, request: "tiny") { counter.hit() }
        socket.enqueueTracked(payload, ticket: ticket)
        try await wait { ticket.snapshot().phase == .allWritten && server.frames.count == 1 && counter.value == 2 }
        #expect(ticket.snapshot().written == payload.count + 1 && counter.value == 2)
        socket.enqueueTracked(payload, ticket: ticket) // Refused without a phase change.
        socket.send(Data("barrier".utf8))
        try await wait { server.frames.count == 2 }
        #expect(server.frames == [payload, Data("barrier".utf8)])
        #expect(counter.value == 2) // Real barrier proves duplicate queue job ran.
    }
    @Test func exactFrameAndOriginalSocketRejectRetargeting() async throws {
        let one = try TicketWire(), two = try TicketWire(); defer { one.close(); two.close() }
        let a = try Socket(path: one.path), b = try Socket(path: two.path)
        defer { a.close(); b.close() }; a.start(); b.start()
        let ticket = a.prepareTracked(Data("owned".utf8), request: "one")
        b.enqueueTracked(Data("owned".utf8), ticket: ticket)
        try await wait { ticket.snapshot().phase == .notEnqueued }
        #expect(ticket.snapshot().written == 0 && two.frames.isEmpty && one.frames.isEmpty)
        let altered = a.prepareTracked(Data("original".utf8), request: "two")
        a.enqueueTracked(Data("changed".utf8), ticket: altered)
        try await wait { altered.snapshot().phase == .notEnqueued }
        #expect(altered.snapshot().written == 0 && one.frames.isEmpty)
    }
    @Test func abandonedOriginalKeepsOneLateDigestAndCannotBecomeDelivered() async throws {
        let server = try TicketWire(); defer { server.close() }
        let socket = try Socket(path: server.path); defer { socket.close() }; socket.start()
        let ticket = socket.sendTracked(Data("original".utf8), request: "request")
        var ledger = NativeOriginalReplyLedger()
        let actualMutation1 = ledger.reserve("request", ticket: ticket, connection: ticket.snapshot().connection)
        #expect(actualMutation1)
        try await wait { ticket.snapshot().phase == .allWritten }
        ledger.abandon("request")
        let actualMutation2 = ledger.observedEnvelope("request", sha256: String(repeating: "a", count: 64))
        #expect(actualMutation2 == .abandonedEnvelope)
        let actualMutation3 = ledger.deliveredEnvelope("request")
        #expect(!actualMutation3 && ledger.contains("request") && ledger.poisoned)
        let actualMutation4 = ledger.observedEnvelope("request", sha256: String(repeating: "b", count: 64))
        #expect(actualMutation4 == .duplicate)
        #expect(ledger.rows["request"]?.envelopeSHA256 == String(repeating: "a", count: 64))
    }
    @Test func controlledReplyDeliveryFreesOnlyItsTransportSlot() async throws {
        let server = try TicketWire(); defer { server.close() }
        let socket = try Socket(path: server.path); defer { socket.close() }; socket.start()
        var ledger = NativeOriginalReplyLedger()
        // More than32 sequential chunk receipts are possible; unknown rows are
        // never evicted. This loop exercises production transport retirement.
        for n in 0..<70 {
            let id = String(n), ticket = socket.sendTracked(Data(id.utf8), request: id)
            let actualMutation5 = ledger.reserve(id, ticket: ticket, connection: ticket.snapshot().connection)
            #expect(actualMutation5)
            try await wait { ticket.snapshot().phase == .allWritten }
            let actualMutation6 = ledger.observedEnvelope(id, sha256: String(repeating: "c", count: 64))
            #expect(actualMutation6 == .envelope)
            let actualMutation7 = ledger.deliveredEnvelope(id)
            #expect(actualMutation7)
        }
        #expect(ledger.rows.isEmpty && ledger.deliveredDigests.count == 64 && !ledger.poisoned)
        // No NativeVerifiedPhaseReceipt can be instantiated by this transport.
    }
    @Test func controlledUnknownRowsDoNotEvictToAdmitMoreWork() throws {
        let server = try TicketWire(); defer { server.close() }
        let socket = try Socket(path: server.path); defer { socket.close() }
        var ledger = NativeOriginalReplyLedger()
        for n in 0..<32 {
            let id = String(n), ticket = socket.prepareTracked(Data(), request: String(n))
            let actualMutation8 = ledger.reserve(id, ticket: ticket, connection: ticket.snapshot().connection)
            #expect(actualMutation8)
        }
        let extra = socket.prepareTracked(Data(), request: "extra")
        let actualMutation9 = ledger.reserve("extra", ticket: extra, connection: extra.snapshot().connection)
        #expect(!actualMutation9)
        ledger.abandon("0")
        let actualMutation10 = ledger.observedEnvelope("0", sha256: String(repeating: "e", count: 64))
        #expect(actualMutation10 == .abandonedEnvelope)
        #expect(ledger.rows.count == 32 && ledger.contains("0"))
        let actualMutation11 = ledger.reserve("extra", ticket: extra, connection: extra.snapshot().connection)
        #expect(!actualMutation11)
    }
    @Test func controlledSourceLossIsStickyAndUnwrittenReplyIsUnknown() throws {
        let server = try TicketWire(); defer { server.close() }
        let socket = try Socket(path: server.path); defer { socket.close() }
        let ticket = socket.prepareTracked(Data("not-sent".utf8), request: "original")
        var ledger = NativeOriginalReplyLedger()
        let actualMutation12 = ledger.reserve("original", ticket: ticket, connection: ticket.snapshot().connection)
        #expect(actualMutation12)
        let actualMutation13 = ledger.observedEnvelope("original", sha256: String(repeating: "d", count: 64))
        #expect(actualMutation13 == .unknown)
        ledger.sourceLost()
        let actualMutation14 = ledger.deliveredEnvelope("original")
        #expect(!actualMutation14 && ledger.contains("original"))
        let later = socket.prepareTracked(Data(), request: "later")
        let actualMutation15 = ledger.reserve("later", ticket: later, connection: later.snapshot().connection)
        #expect(!actualMutation15)
    }
}
private final class TicketWire: @unchecked Sendable {
    enum Failure: Error { case setup }
    let path: String
    private let directory: URL
    private let lock = NSLock(), worker = DispatchGroup()
    private var listener: Int32 = -1, client: Int32 = -1
    private var stopping = false, seen: [Data] = []
    var frames: [Data] { lock.lock(); defer { lock.unlock() }; return seen }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ticket-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("wire").path
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.setup }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure.setup }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, chmod(path, 0o600) == 0, listen(listener, 1) == 0 else { _ = Darwin.close(listener); listener = -1; throw Failure.setup }
        worker.enter()
        DispatchQueue(label: "owned.original-ticket.fixture").async { [self] in defer { worker.leave() }; serve() }
    }
    private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    func close() {
        lock.lock(); stopping = true; let active = client; lock.unlock()
        if active >= 0 { _ = Darwin.shutdown(active, SHUT_RDWR) }
        guard worker.wait(timeout: .now() + 6) == .success else { Issue.record("Owned ticket fixture worker did not stop"); return }
        lock.lock(); let a = client, l = listener; client = -1; listener = -1; lock.unlock()
        if a >= 0 { _ = Darwin.close(a) }; if l >= 0 { _ = Darwin.close(l) }
        try? FileManager.default.removeItem(at: directory)
    }
    private func serve() {
        lock.lock(); let original = listener; lock.unlock()
        var ready = pollfd(fd: original, events: Int16(POLLIN), revents: 0)
        guard !stopped, poll(&ready, 1, 4000) > 0, !stopped else { return }
        let fd = Darwin.accept(original, nil, nil); guard fd >= 0 else { return }
        lock.lock(); client = fd; lock.unlock()
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while !stopped {
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 4000) > 0, !stopped else { return }
            let n = Darwin.read(fd, &bytes, bytes.count); guard n > 0 else { return }
            data.append(contentsOf: bytes.prefix(n))
            while let end = data.firstIndex(of: 10) {
                let frame = Data(data[..<end]); data.removeSubrange(...end)
                lock.lock(); seen.append(frame); lock.unlock()
            }
            guard data.count <= Socket.limit else { return }
        }
    }
}

private final class TicketPhaseCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func hit() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
