import Foundation
import WebKit

// Reading a site without a tab: the address a page itself would ask, sent
// from here with the user's cookies for that site, the answer handed back as
// text. A tab costs a page load, a process, and whatever the site decides to
// draw lazily; a first live run of Get to know me spent most of its seventeen
// minutes waiting on them, and X in an agent's tab gave five posts. Gmail's
// unread feed, a message in its print view, a Doc exported as text, Notion's
// own API: one request each.
//
// A GET may go anywhere a tab could. A POST only where a skill says, in a
// `read:` line, that it only reads (Notion's search, its page chunks): any
// other POST is something done, and that happens in the page, under the same
// eyes as a click.

@MainActor
enum AgentRead {
    struct Answer {
        var status = 0
        var type = ""
        var url = ""
        var text = ""
        var cut = false
    }

    nonisolated static let limit = 1_048_576

    static func run(_ url: URL, method: String, body: String?, type: String?, keepHTML: Bool, store: WKWebsiteDataStore,
                    allowed: @escaping @Sendable () -> Bool = { true }, done: @escaping ([String: Any]) -> Void) {
        guard allowed() else { done(["error": "This context was cleared."]); return }
        Task { @MainActor in
            await ChromiumDRMCookies.beforeSending(to: url, from: store)
            send(url, method: method, body: body, type: type, keepHTML: keepHTML, store: store, allowed: allowed, done: done)
        }
    }

    private static func send(_ url: URL, method: String, body: String?, type: String?, keepHTML: Bool, store: WKWebsiteDataStore,
                             allowed: @escaping @Sendable () -> Bool, done: @escaping ([String: Any]) -> Void) {
        store.httpCookieStore.getAllCookies { cookies in
            guard allowed() else { done(["error": "This context was cleared."]); return }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = method
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies.filter { sent($0, to: url) }) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if method == "POST" {
                request.httpBody = (body ?? "{}").data(using: .utf8)
                request.setValue(type ?? "application/json", forHTTPHeaderField: "Content-Type")
                // As the site's own page sends it: some APIs turn away a
                // POST that says it came from nowhere.
                if let scheme = url.scheme, let host = url.host() {
                    request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
                    request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
                }
            }
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            let session = URLSession(configuration: config, delegate: AnswerCookies(store, allowed: allowed), delegateQueue: nil)
            Task {
                defer { session.finishTasksAndInvalidate() }
                do {
                    guard allowed() else { done(["error": "This context was cleared."]); return }
                    let (data, response) = try await session.data(for: request)
                    guard allowed() else { done(["error": "This context was cleared."]); return }
                    take(response, of: request, into: store)
                    let http = response as? HTTPURLResponse
                    let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
                    // A page of megabytes read into words off the main
                    // thread; the answer comes back to it ready.
                    let (text, cut) = await Task.detached(priority: .userInitiated) { read(data, type: type, keepHTML: keepHTML) }.value
                    done(["status": http?.statusCode ?? 0, "type": type, "url": response.url?.absoluteString ?? url.absoluteString,
                          "text": text, "cut": cut])
                } catch {
                    done(["error": error.localizedDescription])
                }
            }
        }
    }

    /// Whether a browser would send this cookie with a request to the url.
    nonisolated static func sent(_ cookie: HTTPCookie, to url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if let expires = cookie.expiresDate, expires < Date() { return false }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
        let domain = cookie.domain.lowercased()
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard host == bare || host.hasSuffix("." + bare) else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return path.hasPrefix(cookie.path)
    }

    // MARK: - what the site answers with

    /// The cookies a site sets in its answer, into the store the request's
    /// came from, as a tab takes them. These requests are the tab's sign-in
    /// out on its own, and a site that turns its session over as it answers
    /// (a fresh token, the old one void: Supabase's refresh, a Rails or
    /// Laravel session rewritten) left the tab holding the old one, which
    /// signed you out at its next request, or, where reusing a spent token
    /// reads as theft, everywhere. Dropped, they were: every answer here was
    /// read with cookies off. Only from a host the request went to with
    /// cookies of its own, the rule tabs keep (LastingSignIns): a site you
    /// have never been to, read for a link's summary, leaves nothing.
    nonisolated static func take(_ response: URLResponse?, of request: URLRequest?, into store: WKWebsiteDataStore) {
        guard let http = response as? HTTPURLResponse, let url = http.url,
              request?.value(forHTTPHeaderField: "Cookie") != nil,
              request?.url?.host()?.lowercased() == url.host()?.lowercased() else { return }
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !cookies.isEmpty, let host = url.host()?.lowercased() else { return }
        Task { @MainActor in keep(cookies, from: host, in: store) }
    }
    /// An answer's cookies, all handed to the store without a suspension in
    /// between, so a newer answer's cookies cannot land halfway through and
    /// then be overwritten by these older ones. Synchronous on purpose.
    private static func keep(_ cookies: [HTTPCookie], from host: String, in store:WKWebsiteDataStore) {
        for cookie in cookies where may(host, set: cookie) { store.httpCookieStore.setCookie(cookie) }
    }

    /// Whether a browser takes this cookie from this host: parsing takes
    /// any Domain an answer names, and the store any cookie it is handed,
    /// so a page read here could otherwise set google.com's. The host
    /// itself or a name it is under, never a public suffix (Vault.registrable).
    static func may(_ host: String, set cookie: HTTPCookie) -> Bool {
        var domain = cookie.domain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        guard !domain.isEmpty, host == domain || host.hasSuffix("." + domain) else { return false }
        let site = Vault.registrable(host)
        return domain == site || domain.hasSuffix("." + site)
    }

    /// The Safari yab's pages say they are, so a site answers as it does
    /// the page.
    static var userAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) " + Web.userAgentName
    }

    // MARK: - a page as text

    /// A page's words, its lines kept (HTMLText).
    nonisolated static func plain(_ html: String) -> String { HTMLText.plain(html) }

    /// An answer's body as the reader hands it on: words for a page unless
    /// the markup is asked for, and no more than `limit` characters, with
    /// whether it was cut.
    nonisolated static func read(_ data: Data, type: String, keepHTML: Bool) -> (text: String, cut: Bool) {
        MainBudget.chunk("agentread.text") {
            var text = String(decoding: data, as: UTF8.self)
            if type.contains("html"), !keepHTML { text = plain(text) }
            let cut = text.count > limit
            return (cut ? String(text.prefix(limit)) : text, cut)
        }
    }
}

/// AgentRead.take for every answer of a redirect chain too; `follow` false
/// stops at the first one, which is then the answer.
final class AnswerCookies: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let store: WKWebsiteDataStore
    let follow: Bool
    let allowed: @Sendable () -> Bool

    init(_ store: WKWebsiteDataStore, follow: Bool = true, allowed: @escaping @Sendable () -> Bool = { true }) {
        self.store = store
        self.follow = follow
        self.allowed = allowed
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard allowed(), let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { completionHandler(nil); return }
        AgentRead.take(response, of: task.currentRequest, into: store)
        completionHandler(follow ? request : nil)
    }
}
