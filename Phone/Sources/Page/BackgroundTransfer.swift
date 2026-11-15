import Foundation

/// The rules for handing a WebKit download to the system's background
/// transfer (BackgroundDownloads): which files may go, the request the system
/// sends for them, and what Yab keeps of them while the system holds the task.
/// Foundation only, so the rules are testable without a page.
///
/// A file goes only when the system can fetch it again exactly as WebKit did:
/// not private, an anonymous GET with no body, over http(s), answered with
/// the whole file. Cookies, authorization, blob:, data:, POST, private tabs
/// and partial answers stay in WebKit for the time iOS gives a background app.
/// WebKit's resume data is documented only for `WKWebView.resumeDownload`,
/// never for URLSession, so the system starts the file again from its first
/// byte at the URL that last served it.
nonisolated enum BackgroundTransfer {
    /// What the row needs while the system holds the task, and after a
    /// relaunch: no URL or credentials. The URL lives in the system's task.
    struct Record: Codable, Equatable, Sendable {
        let id: UUID
        var name: String
        /// As Site Settings keys it.
        var host: String
        var total: Int64?
        /// The session's own number for the task, in case the system ever
        /// returns it without its description.
        var task: Int?
    }

    /// Background sessions follow redirects without consulting the app.
    /// Carry no credentials or full referrer that could reach another host.
    static let carriedHeaders = ["User-Agent", "Accept", "Accept-Language"]

    /// The URL the system may fetch again, or nil when the transfer must stay
    /// in WebKit.
    static func eligibleURL(original: URLRequest?, response: URLResponse?, isPrivate: Bool) -> URL? {
        guard !isPrivate, let original,
              (original.httpMethod ?? "GET").uppercased() == "GET",
              original.httpBody == nil, original.httpBodyStream == nil,
              isWeb(original.url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = http.url, isWeb(url) else { return nil }
        return url
    }

    /// Only anonymous requests may leave WebKit. URLSession forwards a
    /// manual Cookie header across redirects even with its cookie jar off.
    static func request(for url: URL, original: URLRequest?, page: String?, cookies: [HTTPCookie],
                        now: Date = Date()) -> URLRequest? {
        guard Self.cookies(cookies, for: url, page: page, now: now).isEmpty,
              original?.value(forHTTPHeaderField: "Cookie") == nil,
              original?.value(forHTTPHeaderField: "Authorization") == nil else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // The session must not add cookies from another website store.
        request.httpShouldHandleCookies = false
        for name in carriedHeaders {
            if let value = original?.value(forHTTPHeaderField: name) { request.setValue(value, forHTTPHeaderField: name) }
        }
        return request
    }

    /// The cookies a browser sends with a top-level GET of `url` from the page
    /// at `page` (RFC 6265 domain, path, Secure and expiry; SameSite=Strict
    /// only to the page's own site).
    static func cookies(_ all: [HTTPCookie], for url: URL, page: String?, now: Date = Date()) -> [HTTPCookie] {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return [] }
        let secure = url.scheme?.lowercased() == "https"
        let path = url.path.isEmpty ? "/" : url.path
        return all.filter { cookie in
            if let expires = cookie.expiresDate, expires <= now { return false }
            if cookie.isSecure, !secure { return false }
            guard domainMatches(cookie.domain, host), pathMatches(cookie.path, path) else { return false }
            if cookie.sameSitePolicy == .sameSiteStrict { return sameSite(page, host) }
            return true
        }
    }

    /// A leading dot is a Domain cookie (the host or below it); without one
    /// the cookie is the host's alone.
    static func domainMatches(_ domain: String, _ host: String) -> Bool {
        let domain = domain.lowercased()
        guard domain.hasPrefix(".") else { return host == domain }
        return host == domain.dropFirst() || host.hasSuffix(domain)
    }

    static func pathMatches(_ cookiePath: String, _ path: String) -> Bool {
        let cookiePath = cookiePath.isEmpty ? "/" : cookiePath
        guard path.hasPrefix(cookiePath) else { return false }
        return path.count == cookiePath.count || cookiePath.hasSuffix("/")
            || path[path.index(path.startIndex, offsetBy: cookiePath.count)] == "/"
    }

    static func sameSite(_ page: String?, _ host: String) -> Bool {
        guard let page = page?.lowercased(), !page.isEmpty else { return false }
        return host == page || host.hasSuffix("." + page) || page.hasSuffix("." + host)
    }

    /// The system hands over the body of an error page as readily as a file.
    static func delivered(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode) && http.statusCode != 204 && http.statusCode != 206
    }

    /// Stop pressed in Yab. The system cancelling on its own (Yab swiped
    /// away, background updates off, no room) says why, and the row keeps
    /// Retry.
    static func stoppedByPerson(_ error: Error?) -> Bool {
        guard let error = error as? URLError, error.code == .cancelled else { return false }
        return error.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] == nil
    }

    /// A row for a task the system returned without its record.
    static func recovered(_ id: UUID, task: URLSessionTask) -> Record {
        let url = task.originalRequest?.url
        let suggested = task.response?.suggestedFilename ?? url?.lastPathComponent ?? ""
        let name = suggested.isEmpty ? "Download" : (suggested as NSString).lastPathComponent
        let total = task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : nil
        return Record(id: id, name: name, host: url?.host() ?? "", total: total, task: task.taskIdentifier)
    }

    private static func isWeb(_ url: URL?) -> Bool { ["http", "https"].contains(url?.scheme?.lowercased() ?? "") }
}
