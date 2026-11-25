import Foundation

// What the ad blocker reads, on the Mac (Shield) and on the iPhone
// (Phone/Sources/Page/Shield.swift) alike: the lists uBlock Origin reads, the
// short list built in that stands in before they arrive, and how a list is
// fetched. Foundation only, so the iPhone app compiles this file as it is,
// with Filters beside it, and both devices block the same things.

enum ShieldLists {
    /// Goes up whenever Filters or `base` changes what a list comes out as:
    /// every device compiles the lists it keeps again, once.
    static let schema = 16

    struct Source: Sendable {
        let name: String
        let url: URL
        /// Anything shorter is an error page, not a list.
        let least: Int
    }

    /// In the order they are read, the most useful first: over the cap,
    /// the last ones are what is left out. The addresses are the ones
    /// uBlock Origin itself reads.
    static let sources: [Source] = [
        Source(name: "easylist", url: URL(string: "https://easylist.to/easylist/easylist.txt")!, least: 100_000),
        Source(name: "easyprivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!, least: 100_000),
        Source(name: "ublock-filters", url: URL(string: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt")!, least: 20_000),
        Source(name: "ublock-badware", url: URL(string: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/badware.txt")!, least: 10_000),
        Source(name: "ublock-privacy", url: URL(string: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/privacy.txt")!, least: 10_000),
        Source(name: "ublock-unbreak", url: URL(string: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/unbreak.txt")!, least: 10_000),
        Source(name: "ublock-quick-fixes", url: URL(string: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/quick-fixes.txt")!, least: 1_000),
        Source(name: "peter-lowe", url: URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext")!, least: 10_000),
    ]

    /// What a list says of itself: how many rules it has (its lines that
    /// Filters reads as rules, comments and headers left out), the title
    /// its header gives it, and when its makers last changed it.
    struct Facts: Equatable, Sendable {
        var rules: Int
        var title: String?
        var updated: Date?
    }

    static func facts(_ text: String) -> Facts {
        var facts = Facts(rules: 0)
        var read = 0
        for raw in text.utf8.split(separator: UInt8(ascii: "\n")) {
            let line = String(Substring(raw)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            read += 1
            if line.hasPrefix("!") || (line.hasPrefix("#") && !line.hasPrefix("##") && !line.hasPrefix("#@#")
                                       && !line.hasPrefix("#?#") && !line.hasPrefix("#$#")) {
                // The header is at the top: "! Title: AdGuard Annoyances".
                guard read < 200 else { continue }
                let words = line.drop { $0 == "!" || $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if facts.title == nil, let value = header(words, "Title") { facts.title = value }
                if facts.updated == nil {
                    for key in ["Last modified", "TimeUpdated", "Updated", "Last updated"] {
                        if let value = header(words, key), let date = date(value) { facts.updated = date; break }
                    }
                }
                continue
            }
            if line.hasPrefix("[") { continue }
            facts.rules += 1
        }
        return facts
    }

    private static func header(_ line: String, _ key: String) -> String? {
        guard line.count > key.count, line.lowercased().hasPrefix(key.lowercased() + ":") else { return nil }
        let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// "2026-10-24T10:21:11.000Z" (AdGuard), "24 Oct 2026 10:02 UTC"
    /// (EasyList), or a bare day.
    private static func date(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let words = DateFormatter()
        words.locale = Locale(identifier: "en_US_POSIX")
        words.timeZone = TimeZone(identifier: "UTC")
        for format in ["d MMM yyyy HH:mm 'UTC'", "d MMM yyyy HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "d MMM yyyy"] {
            words.dateFormat = format
            if let date = words.date(from: value) { return date }
        }
        return nil
    }

    static let week: TimeInterval = 7 * 24 * 3600
    /// The largest list is about 2 MB; anything past this is not a list.
    static let most = 16 << 20

    /// One list, fetched with no cookies and no cache, so the hosts learn
    /// nothing about whoever asks. Given up past `most` bytes, and on a
    /// redirect anywhere but https: yab lets pages load plain http, and a
    /// list is what decides what every page loads. `lowData` false leaves
    /// it for later on a network the person asked to spare (Low Data Mode).
    final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let url: URL
        private let most: Int
        private let lowData: Bool
        // Touched only on the session's own serial queue.
        private var got = Data()
        private var done: CheckedContinuation<Data?, Never>?

        init(_ url: URL, most: Int, lowData: Bool = true) {
            self.url = url
            self.most = most
            self.lowData = lowData
        }

        var data: Data? {
            get async {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.allowsConstrainedNetworkAccess = lowData
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                defer { session.finishTasksAndInvalidate() }
                return await withCheckedContinuation { done in
                    session.delegateQueue.addOperation {
                        self.done = done
                        let request = URLRequest(url: self.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
                        session.dataTask(with: request).resume()
                    }
                }
            }
        }

        private func finish(_ data: Data?) {
            done?.resume(returning: data)
            done = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme == "https" ? request : nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let http = response as? HTTPURLResponse
            guard http?.statusCode == 200, response.expectedContentLength <= Int64(most) else {
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            got.append(data)
            if got.count > most { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            // A redirect refused ends here too, with its 3xx and no error.
            let ok = error == nil && (task.response as? HTTPURLResponse)?.statusCode == 200 && got.count <= most
            finish(ok ? got : nil)
        }
    }

    /// Always compiled in first, and all there is before the first lists
    /// arrive: third parties whose only job is to watch or to sell (a
    /// site's own scripts are the site), the few slots that are reliably an
    /// advertisement and nothing else, and YouTube's, which no general list
    /// reaches (Lean's, MIT).
    static let base = """
    ||doubleclick.net^$third-party
    ||googlesyndication.com^$third-party
    ||googleadservices.com^$third-party
    ||googletagservices.com^$third-party
    ||google-analytics.com^$third-party
    ||googletagmanager.com^$third-party
    ||adservice.google.com^$third-party
    ||amazon-adsystem.com^$third-party
    @@||unagi-eu.amazon.com^$domain=amazon.com|amazon.co.uk|amazon.de|amazon.fr|amazon.it|amazon.es|amazon.ca|amazon.co.jp|amazon.in|amazon.com.au
    @@||unagi.amazon.com^$domain=amazon.com|amazon.co.uk|amazon.de|amazon.fr|amazon.it|amazon.es|amazon.ca|amazon.co.jp|amazon.in|amazon.com.au
    ||adnxs.com^$third-party
    ||adsrvr.org^$third-party
    ||criteo.com^$third-party
    ||criteo.net^$third-party
    ||taboola.com^$third-party
    ||outbrain.com^$third-party
    ||rubiconproject.com^$third-party
    ||pubmatic.com^$third-party
    ||openx.net^$third-party
    ||casalemedia.com^$third-party
    ||smartadserver.com^$third-party
    ||sharethrough.com^$third-party
    ||indexww.com^$third-party
    ||bidswitch.net^$third-party
    ||33across.com^$third-party
    ||teads.tv^$third-party
    ||moatads.com^$third-party
    ||adroll.com^$third-party
    ||scorecardresearch.com^$third-party
    ||quantserve.com^$third-party
    ||chartbeat.com^$third-party
    ||hotjar.com^$third-party
    ||mouseflow.com^$third-party
    ||fullstory.com^$third-party
    ||clarity.ms^$third-party
    ||mixpanel.com^$third-party
    ||amplitude.com^$third-party
    ||segment.com^$third-party
    ||segment.io^$third-party
    ||branch.io^$third-party
    ||appsflyer.com^$third-party
    ||adjust.com^$third-party
    ||analytics.tiktok.com^$third-party
    ||connect.facebook.net^$third-party
    ||ads-twitter.com^$third-party
    ||analytics.twitter.com^$third-party
    ##.adsbygoogle
    ##ins.adsbygoogle
    ##[id^="google_ads_"]
    ##[id^="div-gpt-ad"]
    ##[id^="taboola-"]
    ###taboola-below-article
    ##iframe[src*="doubleclick.net"]
    ##iframe[src*="googlesyndication"]
    ##iframe[src*="amazon-adsystem"]
    ||googleads.g.doubleclick.net^
    ||static.doubleclick.net^
    ||youtube.com/api/stats/ads
    ||youtube.com/pagead/
    ||youtube.com/ptracking
    youtube.com##.ytp-ad-module
    youtube.com##.ytp-ad-player-overlay
    youtube.com##.ytp-ad-text
    youtube.com##.ytp-ad-message-container
    youtube.com##.ytp-ad-image-overlay
    youtube.com###player-ads
    youtube.com##ytd-ad-slot-renderer
    youtube.com##ytd-display-ad-renderer
    youtube.com##ytd-promoted-sparkles-web-renderer
    youtube.com##ytd-in-feed-ad-layout-renderer
    youtube.com###masthead-ad
    youtube.com##ytd-search-pyv-renderer
    youtube.com##ytd-companion-slot-renderer
    youtube.com##.ytp-ad-overlay-container
    youtube.com##.ytp-featured-product
    """
}
