import AppKit
import Security
import SecurityInterface
import SwiftUI
import WebKit

// Security, Chrome's panel of that name, in yab's own words and rows: how
// the page's connection is made, its certificate, whether everything on
// it came over HTTPS, and what the site may use on this Mac.
//
// The certificate is the one WebKit trusted for the page. The protocol and
// the cipher aren't told to an app by WebKit, so they are read off a
// connection of yab's own to the same server when the panel opens: one
// HEAD request to the page's origin, with no cookies and nothing kept.

struct SecurityReport: Equatable {
    struct Line: Equatable, Identifiable {
        enum State: Equatable { case good, bad, neutral }
        let title: String
        let detail: String
        let state: State
        var id: String { title }
    }

    var lines: [Line] = []
}

@MainActor
final class SecurityReader: ObservableObject {
    @Published private(set) var report: SecurityReport?
    private var page: URL?
    /// The document read, by when it began (DevLog.since): a reload is
    /// read again at the same address.
    private var document: Date?
    private var session: URLSession?

    /// The page read again when it isn't the document last read.
    func read(_ tab: Tab) {
        guard let web = tab.webKitOnly("WebKit security inspection", build: false), let url = tab.address, url != page || tab.devLog.since != document else { return }
        page = url
        document = tab.devLog.since
        shown = web
        report = nil
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "https" || scheme == "http" else {
            report = SecurityReport(lines: [.init(title: "Not a page on the web", detail: url.absoluteString, state: .neutral)])
            return
        }
        var lines: [SecurityReport.Line] = []
        let secure = scheme == "https"
        let certificate = secure ? Self.certificate(web.serverTrust, host: url.host() ?? "") : nil
        lines.append(Self.permissions(url))
        let mixed = web.hasOnlySecureContent
        // What the page loaded, counted by the scheme it came over.
        web.evaluateJavaScript("(function(){var e=performance.getEntriesByType('resource').map(function(x){return x.name});var n=e.length,p=e.filter(function(u){return u.indexOf('http:')===0}).length;return [n,p]})()",
                                in: nil, in: Web.world) { [weak self] result in
            let counts = (try? result.get()) as? [Int] ?? []
            self?.finish(url: url, secure: secure, certificate: certificate, mixed: mixed, counts: counts, rest: lines)
        }
    }

    private func finish(url: URL, secure: Bool, certificate: SecurityReport.Line?, mixed: Bool, counts: [Int], rest: [SecurityReport.Line]) {
        guard url == page else { return }
        var lines: [SecurityReport.Line] = []
        let requests: SecurityReport.Line = {
            let total = counts.first ?? 0, plain = counts.count > 1 ? counts[1] : 0
            if !secure { return .init(title: "The page itself came over plain HTTP", detail: "Anyone on the network can read and change it", state: .bad) }
            if plain > 0 || !mixed {
                return .init(title: "Some of the page came over plain HTTP", detail: plain > 0 ? "\(plain) of \(total + 1) requests" : "Mixed content on the page", state: .bad)
            }
            return .init(title: "Every request over HTTPS", detail: "\(total + 1) of \(total + 1) requests", state: .good)
        }()
        let connection: SecurityReport.Line = secure
            ? .init(title: "Connection", detail: "Reading…", state: .neutral)
            : .init(title: "Connection is not secure", detail: "HTTP, not encrypted", state: .bad)
        lines = [connection] + (certificate.map { [$0] } ?? []) + [requests] + rest
        report = SecurityReport(lines: lines)
        if secure {
            connect(url)
            if let trust = web(url)?.serverTrust { judge(trust, host: url.host() ?? "", url: url) }
        }
    }

    /// The page's web view while it still shows `url`.
    private weak var shown: WKWebView?
    private func web(_ url: URL) -> WKWebView? { shown?.url == url ? shown : nil }

    /// Whether the certificate is trusted, judged off the main thread:
    /// judging can wait on the network (revocation, a missing intermediate).
    /// On a copy of WebKit's trust, which WebKit may be using itself.
    private func judge(_ trust: SecTrust, host: String, url: URL) {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var copy: SecTrust?
            SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, host as CFString), &copy)
            let valid = copy.map { SecTrustEvaluateWithError($0, nil) } ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, url == self.page, var report = self.report,
                          let at = report.lines.firstIndex(where: { $0.title == Self.judging }) else { return }
                    let line = report.lines[at]
                    report.lines[at] = .init(title: valid ? "Certificate is valid" : "Certificate is not trusted", detail: line.detail, state: valid ? .good : .bad)
                    self.report = report
                }
            }
        }
    }

    private static let judging = "Certificate"

    /// The protocol and the cipher, off a HEAD of yab's own.
    private func connect(_ url: URL) {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        parts.path = "/"
        parts.query = nil
        parts.fragment = nil
        guard let origin = parts.url else { return }
        let listener = Metrics()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: listener, delegateQueue: .main)
        self.session?.invalidateAndCancel()
        self.session = session
        var request = URLRequest(url: origin)
        request.httpMethod = "HEAD"
        listener.done = { [weak self] tls, cipher in
            MainActor.assumeIsolated {
                guard let self, url == self.page, var report = self.report, !report.lines.isEmpty else { return }
                report.lines[0] = tls.map { .init(title: "Connection is secure", detail: [$0, cipher].compactMap { $0 }.joined(separator: " · "), state: .good) }
                    ?? .init(title: "Connection is encrypted", detail: "HTTPS", state: .good)
                self.report = report
            }
        }
        session.dataTask(with: request).resume()
    }

    private final class Metrics: NSObject, URLSessionTaskDelegate {
        var done: ((String?, String?) -> Void)?

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            let last = metrics.transactionMetrics.last
            let tls = last?.negotiatedTLSProtocolVersion.map(Self.name)
            let cipher = last?.negotiatedTLSCipherSuite.map(Self.cipher)
            done?(tls, cipher)
            done = nil
            session.finishTasksAndInvalidate()
        }

        static func name(_ version: tls_protocol_version_t) -> String {
            switch version {
            case .TLSv13: return "TLS 1.3"
            case .TLSv12: return "TLS 1.2"
            case .TLSv11: return "TLS 1.1"
            case .TLSv10: return "TLS 1.0"
            default: return "TLS"
            }
        }

        static func cipher(_ suite: tls_ciphersuite_t) -> String {
            switch suite {
            case .AES_128_GCM_SHA256: return "AES_128_GCM_SHA256"
            case .AES_256_GCM_SHA384: return "AES_256_GCM_SHA384"
            case .CHACHA20_POLY1305_SHA256: return "CHACHA20_POLY1305_SHA256"
            case .ECDHE_ECDSA_WITH_AES_128_GCM_SHA256: return "ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
            case .ECDHE_ECDSA_WITH_AES_256_GCM_SHA384: return "ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
            case .ECDHE_RSA_WITH_AES_128_GCM_SHA256: return "ECDHE_RSA_WITH_AES_128_GCM_SHA256"
            case .ECDHE_RSA_WITH_AES_256_GCM_SHA384: return "ECDHE_RSA_WITH_AES_256_GCM_SHA384"
            case .ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256: return "ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
            case .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256: return "ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"
            default: return "0x" + String(suite.rawValue, radix: 16, uppercase: true)
            }
        }
    }

    /// The certificate WebKit trusted: whose, by whom, until when; whether
    /// it is trusted comes after (`judge`).
    private static func certificate(_ trust: SecTrust?, host: String) -> SecurityReport.Line {
        guard let trust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return .init(title: "No certificate", detail: "WebKit kept none for this page", state: .bad)
        }
        let subject = SecCertificateCopySubjectSummary(leaf) as String? ?? "Unknown"
        let issuer = chain.count > 1 ? SecCertificateCopySubjectSummary(chain[1]) as String? : nil
        var until: Date?
        let key = kSecOIDX509V1ValidityNotAfter
        if let values = SecCertificateCopyValues(leaf, [key] as CFArray, nil) as? [CFString: [CFString: Any]],
           let number = values[key]?[kSecPropertyKeyValue] as? NSNumber {
            until = Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        let when = until.map { "until " + $0.englishFormatted(date: .abbreviated, time: .omitted) }
        let detail = [subject, issuer.map { "issued by " + $0 }, when].compactMap { $0 }.joined(separator: " · ")
        return .init(title: judging, detail: detail, state: .neutral)
    }

    /// What the site may use on this Mac, as yab keeps it.
    private static func permissions(_ url: URL) -> SecurityReport.Line {
        let host = url.host() ?? ""
        let site = Browser.origin(of: url) ?? host
        var allowed: [String] = [], refused: [String] = []
        for (type, name) in [(PageCapture.camera, "camera"), (.microphone, "microphone"), (.cameraAndMicrophone, "camera and microphone")] {
            if let said = Browser.remembered(Browser.captureKey(site, type), host: host, type) { said ? allowed.append(name) : refused.append(name) }
        }
        if let said = Store.settings.object(forKey: "location.\(host)") as? Bool { said ? allowed.append("location") : refused.append("location") }
        if let said = MainActor.assumeIsolated({ SiteNotices.said(site) }) { said ? allowed.append("notifications") : refused.append("notifications") }
        if allowed.isEmpty && refused.isEmpty {
            return .init(title: "No permissions kept", detail: "The site hasn’t been allowed the camera, the microphone, your location or notifications", state: .neutral)
        }
        let detail = [allowed.isEmpty ? nil : "Allowed: " + allowed.joined(separator: ", "),
                      refused.isEmpty ? nil : "Refused: " + refused.joined(separator: ", ")].compactMap { $0 }.joined(separator: " · ")
        return .init(title: allowed.isEmpty ? "Permissions refused" : "Permissions allowed", detail: detail, state: .neutral)
    }
}

/// The panel: a row for each, its dot green when all is well.
struct DevSecurity: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var log: DevLog
    @StateObject private var reader = SecurityReader()

    var body: some View {
        Group {
            if let report = reader.report {
                ThreadScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(report.lines) { line in row(line) }
                        if let trust = tab.webKitOnly("WebKit security inspection", build: false)?.serverTrust {
                            Button("View certificate") {
                                if let window = browser.devWindow { SFCertificatePanel.shared().beginSheet(for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust, showGroup: true) }
                            }.buttonStyle(.yab(.quiet, .small)).padding(DevLook.padding)
                        }
                        Text("Origins").font(.system(size: 12, weight: .semibold)).padding(DevLook.padding)
                        ForEach(origins, id: \.self) { origin in
                            HStack { Text(origin).textSelection(.enabled); Spacer(); Text(origin.hasPrefix("https:") ? "HTTPS" : "HTTP").foregroundStyle(origin.hasPrefix("https:") ? Color.green : DevLook.red) }.font(DevMono.font(11)).padding(DevLook.padding)
                        }
                    }
                }
            } else {
                DevQuiet(words: "Reading the connection…")
            }
        }
        .onAppear { reader.read(tab) }
        .onChange(of: tab.address) { reader.read(tab) }
        .onChange(of: log.since) { reader.read(tab) }
    }

    private var origins: [String] {
        let urls = tab.netLog.rows.compactMap { URL(string: $0.url) } + [tab.address].compactMap { $0 }
        return Array(Set(urls.compactMap { url in
            guard let scheme = url.scheme, let host = url.host(), ["http", "https"].contains(scheme) else { return nil }
            return scheme + "://" + host + (url.port.map { ":\($0)" } ?? "")
        })).sorted()
    }
    private func row(_ line: SecurityReport.Line) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color(line.state))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                    .font(.system(size: 12, weight: .medium))
                Text(line.detail)
                    .font(DevMono.font(11))
                    .foregroundStyle(Palette.muted)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DevLook.padding)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.ink.opacity(0.05)).frame(height: 1) }
    }

    private func color(_ state: SecurityReport.Line.State) -> Color {
        switch state {
        case .good: return Color(nsColor: .systemGreen)
        case .bad: return DevLook.red
        case .neutral: return Palette.ink.opacity(0.3)
        }
    }
}
