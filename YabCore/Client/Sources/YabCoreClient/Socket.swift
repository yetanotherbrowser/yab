import Foundation
import Darwin
import CryptoKit


/// Transport facts ONLY. No peer/document/native phase authority. Constructor
/// is confined to the actual Socket; caller JSON cannot manufacture this ticket.
final class SocketWriteTicket: @unchecked Sendable {
    enum Phase: String, Sendable { case created, enqueued, allWritten, notEnqueued, unknown }
    struct Snapshot: Equatable, Sendable {
        let connection, request, frameSHA256: String
        let total, written: Int
        let phase: Phase
    }
    private let lock = NSLock()
    private let connection, request, frameSHA256: String
    private let total: Int
    private var written = 0
    private var phase: Phase = .created
    private let changed: @Sendable () -> Void
    fileprivate init(connection: String, request: String, frame: Data, changed: @escaping @Sendable () -> Void) {
        self.connection = connection; self.request = request; self.total = frame.count
        self.frameSHA256 = SHA256.hash(data: frame).map { String(format: "%02x", $0) }.joined()
        self.changed = changed
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(connection: connection, request: request, frameSHA256: frameSHA256,
                        total: total, written: written, phase: phase)
    }
    fileprivate func queued() {
        lock.lock(); let before = phase
        if phase == .created { phase = .enqueued }
        let transitioned = before != phase; lock.unlock()
        if transitioned { changed() }
    }
    fileprivate func advance(_ bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock(); let before = phase
        if phase == .enqueued, bytes <= total - written {
            written += bytes; if written == total { phase = .allWritten }
        }
        let transitioned = before != phase; lock.unlock()
        // Partial writes update their own byte count without scheduling actor
        // work; only the queued→allWritten transition needs notification.
        if transitioned { changed() }
    }
    fileprivate func refusedBeforeQueue() {
        lock.lock(); let before = phase
        if phase == .created { phase = .notEnqueued }
        let transitioned = before != phase; lock.unlock()
        if transitioned { changed() }
    }
    fileprivate func lost() {
        lock.lock(); let before = phase
        if phase != .allWritten && phase != .notEnqueued { phase = .unknown }
        let transitioned = before != phase; lock.unlock()
        if transitioned { changed() }
    }
}
/// Relative to the CURRENT output buffer, never a global byte dispatch counter.
private struct SocketWriteSpan {
    var before: Int
    let ticket: SocketWriteTicket
    mutating func consumed(_ count: Int) {
        let skipped = min(before, count); before -= skipped
        let remaining = ticket.snapshot().total - ticket.snapshot().written
        ticket.advance(min(count - skipped, remaining))
    }
}

/// All descriptor and buffer access is confined to this queue. No blocking reads
/// or writes run on the UI thread or on the client's actor.
final class Socket: @unchecked Sendable {
    static let limit = 4 * 1024 * 1024
    /// The original-native lane's own ceiling (enqueueTracked refuses past it).
    static let outgoingLimit = 256 * 1024 * 1024
    /// Requests written ahead of the helper's reading. Past it a request waits
    /// its turn here, in order, and is queued once the helper has read enough;
    /// the request admission (YabCoreClient.inFlight) bounds how many wait.
    /// Before, 138 loading tabs each sent the same megabyte of scripts and
    /// overflow ended every page (run 3c40191600534aee); scripts now go once
    /// (ScriptBundles) and a busy helper only slows its writers.
    static let writeWindow = 8 * 1024 * 1024
    /// Frames read and not yet taken by the client. Past either, the socket is
    /// not read until they are: the helper's own budget holds what follows.
    static let readAhead = 256
    static let readAheadBytes = 8 * 1024 * 1024
    private let queue = DispatchQueue(label: "com.yab.core.socket")
    private var fd: Int32
    private let maxWriteBatchBytes: Int
    private let originalLaunch: NativePeerIdentity.LaunchWitness?
    private let originalPeer: NativePeerIdentity?
    private let originalConnection = UUID().uuidString.lowercased()
    private var originalPeerUncertain = false
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var input = Data()
    /// How much of `input` is known to hold no newline. A message of a few
    /// megabytes (a page's picture) arrives in 16 kB reads: looked for from
    /// the start each time, its newline cost the whole buffer again per read,
    /// a picture's bytes read hundreds of times over (R1436).
    private var scanned = 0
    private var output = Data()
    private var trackedWrites: [SocketWriteSpan] = []
    private var parked: [(data: Data, queued: (@Sendable (Error?) -> Void)?)] = []
    private var frames: [Data] = []
    private var frameHead = 0, frameBytes = 0
    private var taker: CheckedContinuation<Data?, Error>?
    private var paused = false
    private var ended = false, endError: Error?
    private var peakOutput = 0, peakFrames = 0
    /// Frames in order, one at a time: the socket is read as they are taken.
    var messages: AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(unfolding: { [self] in try await nextMessage() })
    }

    init(path: String, originalLaunch: NativePeerIdentity.LaunchWitness? = nil, maxWriteBatchBytes: Int = 262_144) throws {
        guard (1...262_144).contains(maxWriteBatchBytes) else { throw YabCoreError.protocolViolation("Invalid socket write batch") }
        self.maxWriteBatchBytes = maxWriteBatchBytes
        self.originalLaunch = originalLaunch
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw YabCoreError.transport("Unix socket path is too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw YabCoreError.transport(String(cString: strerror(errno))) }
        fd = descriptor
        let status = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            let message = String(cString: strerror(errno)); Darwin.close(descriptor)
            throw YabCoreError.transport(message)
        }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid() else {
            Darwin.close(descriptor); throw YabCoreError.transport("Socket peer is not the current user")
        }
        // Optional strict witness failure never changes ordinary routes.
        originalPeer = originalLaunch?.bind(socket: descriptor)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var yes: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
    }
    var originalHandshakeParameters: [String: JSONValue] {
        originalPeer == nil ? [:] : ["originalPeerClientNonce": .string(originalConnection)]
    }
    func acceptedOriginalCounterpart(_ hello: JSONValue) async -> NativeOriginalGroupCounterpart? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard fd >= 0, !originalPeerUncertain, let launch = originalLaunch, let peer = originalPeer else { continuation.resume(returning: nil); return }
                continuation.resume(returning: launch.acceptedCounterpart(socket: fd, original: peer, hello: hello, clientNonce: originalConnection))
            }
        }
    }
    func originalPeerObservation() async -> NativeOriginalPeerObservation {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let launch = originalLaunch, let peer = originalPeer else { continuation.resume(returning: .unavailable); return }
                guard fd >= 0, !originalPeerUncertain else { continuation.resume(returning: .unknown); return }
                guard launch.reobserve(socket: fd, original: peer) == .current else {
                    originalPeerUncertain = true; continuation.resume(returning: .unknown); return
                }
                continuation.resume(returning: .observed(NativeOriginalPeerSource(evidence: peer.evidence, connection: originalConnection)))
            }
        }
    }
    func start() {
        queue.async { [self] in
            guard fd >= 0, readSource == nil else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readReady() }
            readSource = source; source.resume()
        }
    }
    /// One frame, in call order. `queued` says when its bytes are in the
    /// ordered output (or why they never will be): at once while the helper
    /// keeps up, after earlier frames drain when it does not.
    func send(_ data: Data, queued: (@Sendable (Error?) -> Void)? = nil) {
        queue.async { [self] in
            guard fd >= 0 else { queued?(YabCoreError.disconnected); return }
            guard data.count <= Self.limit else { queued?(YabCoreError.protocolViolation("Request too large")); return }
            parked.append((data, queued)); admitParked(); writeReady()
        }
    }
    private func admitParked() {
        while !parked.isEmpty, output.isEmpty || output.count + parked[0].data.count + 1 <= Self.writeWindow {
            let frame = parked.removeFirst()
            output.append(frame.data); output.append(10)
            peakOutput = max(peakOutput, output.count)
            frame.queued?(nil)
        }
    }
    /// Event credit back to the helper: the wire's own frame, never a
    /// request, and never behind requests waiting their turn.
    func credit(bytes: Int, count: Int) {
        let frame = Data("{\"v\":1,\"flow\":{\"bytes\":\(bytes),\"count\":\(count)}}\n".utf8)
        queue.async { [self] in
            guard fd >= 0 else { return }
            output.append(frame); writeReady()
        }
    }
    func flowSnapshot() async -> [String: Int] {
        await withCheckedContinuation { done in
            queue.async { [self] in
                done.resume(returning: ["output": output.count, "parked": parked.count, "frames": frames.count - frameHead,
                                        "frameBytes": frameBytes, "input": input.count, "peakOutput": peakOutput,
                                        "peakFrames": peakFrames, "paused": paused ? 1 : 0])
            }
        }
    }
    /// Actual stream ticket; even allWritten means ONLY this frame's bytes
    /// (including LF) reached Darwin.write, never helper/native application.
    func prepareTracked(_ data: Data, request: String, changed: @escaping @Sendable () -> Void = {}) -> SocketWriteTicket {
        let frame: Data = { var bytes = data; bytes.append(10); return bytes }()
        return SocketWriteTicket(connection: originalConnection, request: request, frame: frame, changed: changed)
    }
    func enqueueTracked(_ data: Data, ticket: SocketWriteTicket) {
        let frame: Data = { var bytes = data; bytes.append(10); return bytes }()
        queue.async { [self] in
            let own = ticket.snapshot()
            let hash = SHA256.hash(data: frame).map { String(format: "%02x", $0) }.joined()
            guard own.phase == .created, own.connection == originalConnection,
                  own.total == frame.count, own.frameSHA256 == hash else {
                ticket.refusedBeforeQueue(); return
            }
            guard fd >= 0, data.count <= Self.limit, trackedWrites.count < 32,
                  frame.count <= Self.outgoingLimit - output.count else {
                ticket.refusedBeforeQueue(); return
            }
            trackedWrites.append(SocketWriteSpan(before: output.count, ticket: ticket))
            output.append(frame); ticket.queued(); writeReady()
        }
    }
    /// Ordinary transport testing/diagnostics. Does NOT grant original authority.
    @discardableResult func sendTracked(_ data: Data, request: String) -> SocketWriteTicket {
        let ticket = prepareTracked(data, request: request)
        enqueueTracked(data, ticket: ticket); return ticket
    }
    func close() { queue.async { [self] in finish(nil) } }
    private func finish(_ error: Error?) {
        guard fd >= 0 else { return }
        originalPeerUncertain = true
        trackedWrites.forEach { $0.ticket.lost() }; trackedWrites.removeAll()
        output.removeAll(keepingCapacity: false); input.removeAll(keepingCapacity: false); scanned = 0
        let waiting = parked; parked.removeAll()
        // A suspended dispatch source must be resumed before it is cancelled.
        if paused { readSource?.resume(); paused = false }
        readSource?.cancel(); writeSource?.cancel()
        readSource = nil; writeSource = nil
        Darwin.close(fd); fd = -1
        // Frames already read are still the helper's last words: delivered,
        // then the end.
        ended = true; endError = error
        if let taker, frameHead == frames.count {
            self.taker = nil
            if let error { taker.resume(throwing: error) } else { taker.resume(returning: nil) }
        }
        waiting.forEach { $0.queued?(error ?? YabCoreError.disconnected) }
    }
    private func nextMessage() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if frameHead < frames.count { continuation.resume(returning: takeFrame()); return }
                if ended {
                    if let endError { continuation.resume(throwing: endError) } else { continuation.resume(returning: nil) }
                    return
                }
                taker = continuation
            }
        }
    }
    private func takeFrame() -> Data {
        let data = frames[frameHead]; frameHead += 1; frameBytes -= data.count
        if frameHead == frames.count { frames.removeAll(keepingCapacity: true); frameHead = 0 }
        else if frameHead > 64, frameHead * 2 > frames.count { frames.removeFirst(frameHead); frameHead = 0 }
        if paused, fd >= 0, frames.count - frameHead < Self.readAhead / 2, frameBytes < Self.readAheadBytes / 2 {
            paused = false; readSource?.resume()
        }
        return data
    }
    private func deliver(_ data: Data) {
        if let taker {
            self.taker = nil; taker.resume(returning: data); return
        }
        frames.append(data); frameBytes += data.count
        peakFrames = max(peakFrames, frames.count - frameHead)
    }
    private func readReady() {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        for _ in 0..<16 {
            guard fd >= 0, !paused else { return }
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n == 0 { finish(nil); return }
            if n < 0 {
                if errno != EAGAIN && errno != EINTR { finish(YabCoreError.transport(String(cString: strerror(errno)))) }
                return
            }
            input.append(contentsOf: buffer.prefix(n))
            while let end = nextNewline() {
                guard input.distance(from: input.startIndex, to: end) <= Self.limit else {
                    finish(YabCoreError.protocolViolation("Incoming message is too large")); return
                }
                let data = Data(input[..<end]); input.removeSubrange(...end)
                scanned = 0
                deliver(data)
            }
            if input.count > Self.limit { finish(YabCoreError.protocolViolation("Incoming message is too large")); return }
            if frames.count - frameHead >= Self.readAhead || frameBytes >= Self.readAheadBytes {
                paused = true; readSource?.suspend(); return
            }
        }
    }
    /// The first newline in `input` past what was already looked through.
    private func nextNewline() -> Data.Index? {
        let from = min(scanned, input.count)
        let found: Int? = input.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > from,
                  let hit = memchr(base + from, 10, raw.count - from) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
        guard let found else { scanned = input.count; return nil }
        return input.index(input.startIndex, offsetBy: found)
    }
    private func writeReady() {
        guard fd >= 0 else { return }
        while !output.isEmpty {
            let n = output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, min($0.count, maxWriteBatchBytes)) }
            if n > 0 {
                // Account this exact write against EACH frame's own span. Older
                // queued bytes can never count as this request's forwarding.
                for index in trackedWrites.indices { trackedWrites[index].consumed(n) }
                trackedWrites.removeAll { $0.ticket.snapshot().phase == .allWritten }
                // Not removeFirst(n): on Data it only slices, so the storage kept every
                // byte ever written, about 0.5 GB a minute while sharing a screen.
                output.removeSubrange(output.startIndex ..< output.startIndex + n)
                admitParked()
            }
            else if n < 0 && errno == EINTR { continue }
            else if n < 0 && errno == EAGAIN {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    source.setEventHandler { [weak self] in self?.writeReady() }
                    writeSource = source; source.resume()
                }
                return
            } else { finish(YabCoreError.transport("Socket write failed")); return }
        }
        writeSource?.cancel(); writeSource = nil
    }
    deinit {
        // Releasing a suspended dispatch source traps: resume it first.
        if paused { readSource?.resume() }
        readSource?.cancel(); writeSource?.cancel()
        if fd >= 0 { Darwin.close(fd) }
    }
}
