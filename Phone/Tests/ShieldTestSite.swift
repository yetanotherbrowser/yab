import Foundation
import Network

/// Pages over plain HTTP on this device, nothing more: a body by path, a
/// redirect to another host name of this device, else the one page with an
/// ad script ShieldStoreTests loads.
final class ShieldTestSite: @unchecked Sendable {
    enum Route: Sendable {
        case page(String)
        /// 302 to the same port on another name, which the frame's own host
        /// then reads (localhost for 127.0.0.1).
        case redirect(host: String, path: String)
    }

    private let queue = DispatchQueue(label: "yab.tests.shield-site")
    private let listener: NWListener
    private let routes: [String: Route]
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init(routes: [String: Route] = [:]) throws {
        self.routes = routes
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, prior: Data())
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                var waiting: CheckedContinuation<Void, Error>? = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self, let continuation = waiting else { return }
                    switch state {
                    case .ready:
                        waiting = nil
                        self.port = self.listener.port!.rawValue
                        continuation.resume()
                    case let .failed(error):
                        waiting = nil
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections = []
        }
    }

    func url(_ path: String, host: String = "127.0.0.1") -> URL { URL(string: "http://\(host):\(port)\(path)")! }

    private func receive(_ connection: NWConnection, prior: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var data = prior
            if let chunk { data.append(chunk) }
            guard let request = String(data: data, encoding: .utf8), request.contains("\r\n\r\n") else {
                if !done { self.receive(connection, prior: data) } else { connection.cancel() }
                return
            }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            connection.send(content: Data(self.response(path).utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func response(_ path: String) -> String {
        let bare = String(path.split(separator: "?", maxSplits: 1).first ?? "")
        switch routes[bare] {
        case let .page(body):
            return Self.ok(body, type: "text/html")
        case let .redirect(host, to):
            return "HTTP/1.1 302 Found\r\nLocation: \(url(to, host: host).absoluteString)\r\nCache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        case nil:
            let script = path.hasPrefix("/preview-ad.js")
            return Self.ok(script ? "window.previewAdLoaded = true;" :
                "<!doctype html><meta name=viewport content=width=device-width><link rel=icon href=data:,><title>Shield store</title><h1>A page</h1><script src='/preview-ad.js'></script>",
                type: script ? "application/javascript" : "text/html")
        }
    }

    private static func ok(_ body: String, type: String) -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: \(type); charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
    }
}
