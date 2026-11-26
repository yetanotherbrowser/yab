import Foundation

/// Search providers' public autocomplete. Each field owns its request and
/// keeps the response only while these words are in that field.
@MainActor
final class SearchSuggestions {
    private var task: Task<Void, Never>?
    private var requestKey: String?
    /// The engine's answer for the words in the field, best first.
    private(set) var items: [Item] = []
    private let session: URLSession

    /// One row of an engine's answer: words to search, or a site Google
    /// names for them (its NAVIGATION result), listed as a site as
    /// Chrome's omnibox lists it.
    enum Item: Equatable, Sendable {
        case words(String)
        case site(URL, title: String)

        /// Still what the words being typed begin.
        func completes(_ typed: String) -> Bool {
            switch self {
            case .words(let words):
                let words = words.lowercased()
                return words.hasPrefix(typed) && words != typed
            case .site(let url, _):
                let key = History.key(for: url)
                return key.hasPrefix(typed) && key != typed
            }
        }
    }

    var words: [String] { items.compactMap { if case .words(let words) = $0 { words } else { nil } } }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 1.5
        session = URLSession(configuration: config)
    }

    deinit { task?.cancel(); session.invalidateAndCancel() }

    func update(_ text: String?, engine: Engine, changed: @escaping @MainActor () -> Void) {
        let language = Locale.preferredLanguages.first ?? "en"
        let key = text.map { engine.rawValue + ":" + language + ":" + $0 }
        guard key != requestKey else { return }
        task?.cancel()
        requestKey = key
        // What still completes the words typed stays till the engine's new
        // answer comes, as in Arc and Chrome: cleared, the rows went at
        // each key and came back a fifth of a second later, the list
        // shrinking and growing under the fingers.
        let typed = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        items = typed.isEmpty ? [] : items.filter { $0.completes(typed) }
        guard let text, let request = Self.request(text, engine: engine, language: language) else { return }
        task = Task { [weak self, session] in
            do {
                try await Task.sleep(for: .milliseconds(160))
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      data.count < 256_000, !Task.isCancelled else { return }
                // Read off the main thread; the field gets the words ready.
                let items = await Task.detached(priority: .userInitiated) {
                    MainBudget.chunk("suggest.parse") { Self.read(data, engine: engine, typed: text) }
                }.value
                guard !Task.isCancelled, let self, self.requestKey == key else { return }
                self.items = items
                changed()
            } catch { /* Typing, timeouts and unavailable providers leave local rows alone. */ }
        }
    }

    nonisolated static func request(_ text: String, engine: Engine, language: String) -> URLRequest? {
        let base: String
        var fields: [URLQueryItem]
        switch engine {
        case .google:
            base = "https://www.google.com/complete/search"
            fields = [URLQueryItem(name: "client", value: "chrome-omni"),
                      URLQueryItem(name: "gs_ri", value: "chrome-ext-ansg"),
                      URLQueryItem(name: "xssi", value: "t"),
                      URLQueryItem(name: "ie", value: "UTF-8"), URLQueryItem(name: "oe", value: "UTF-8"),
                      URLQueryItem(name: "hl", value: language), URLQueryItem(name: "q", value: text)]
        case .duckduckgo:
            base = "https://duckduckgo.com/ac/"
            fields = [URLQueryItem(name: "type", value: "list"), URLQueryItem(name: "q", value: text)]
        case .bing:
            base = "https://api.bing.com/osjson.aspx"
            fields = [URLQueryItem(name: "query", value: text)]
        case .ecosia:
            base = "https://ac.ecosia.org/autocomplete"
            fields = [URLQueryItem(name: "type", value: "list"), URLQueryItem(name: "q", value: text)]
        case .startpage:
            base = "https://www.startpage.com/osuggestions"
            fields = [URLQueryItem(name: "q", value: text)]
        case .kagi:
            base = "https://kagi.com/api/autosuggest"
            fields = [URLQueryItem(name: "q", value: text)]
        case .brave:
            base = "https://search.brave.com/api/suggest"
            fields = [URLQueryItem(name: "q", value: text)]
        case .qwant:
            base = "https://api.qwant.com/v3/suggest"
            fields = [URLQueryItem(name: "q", value: text)]
        case .custom: return nil
        }
        var components = URLComponents(string: base)!
        components.queryItems = fields
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue(language, forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// The words alone, sites left out.
    nonisolated static func parse(_ data: Data, engine: Engine, typed: String) -> [String] {
        read(data, engine: engine, typed: typed).compactMap { if case .words(let words) = $0 { words } else { nil } }
    }

    nonisolated static func read(_ data: Data, engine: Engine, typed: String) -> [Item] {
        let clean = data.starts(with: [41, 93, 125, 39]) ? Data(data.dropFirst(4)) : data
        guard let json = try? JSONSerialization.jsonObject(with: clean) else { return [] }
        var candidates: [Item] = []
        if engine == .qwant,
           let root = json as? [String: Any], let body = root["data"] as? [String: Any],
           let items = body["items"] as? [[String: Any]] {
            candidates = items.compactMap { ($0["value"] as? String).map(Item.words) }
        } else if let root = json as? [Any], root.count > 1, let list = root[1] as? [String] {
            let descriptions = root.count > 2 ? root[2] as? [String] ?? [] : []
            let metadata = root.count > 4 ? root[4] as? [String: Any] : nil
            let kinds = metadata?["google:suggesttype"] as? [String] ?? []
            let details = metadata?["google:suggestdetail"] as? [[String: Any]] ?? []
            let relevances = (metadata?["google:suggestrelevance"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
            let scored = relevances.count == list.count
            var ranked: [(item: Item, relevance: Int)] = []
            for (i, item) in list.enumerated() {
                // Chrome's SearchProvider ranks the answer by the relevance
                // each row carries; without it, in the order given.
                let relevance = scored ? relevances[i] : -i
                if kinds.indices.contains(i), kinds[i].hasPrefix("NAVIGATION") {
                    // A site, never the words of its address to search for
                    // (why c77c2a125 left them out). Only a plain web
                    // address goes in a row.
                    guard let url = site(item) else { continue }
                    let title = descriptions.indices.contains(i) ? descriptions[i] : ""
                    ranked.append((.site(url, title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))), relevance))
                    continue
                }
                let name = details.indices.contains(i)
                    ? (details[i]["google:entityinfo"] as? String).flatMap(entityName) : nil
                ranked.append((.words(name ?? item), relevance))
            }
            // Stable: rows of equal relevance keep the engine's order.
            candidates = ranked.enumerated().sorted {
                $0.element.relevance != $1.element.relevance ? $0.element.relevance > $1.element.relevance : $0.offset < $1.offset
            }.map { $0.element.item }
        }
        var seen = Set([typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()])
        var sites = Set<String>()
        return Array(candidates.compactMap { candidate -> Item? in
            switch candidate {
            case .words(let value):
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.count <= 512, seen.insert(value.lowercased()).inserted else { return nil }
                return .words(value)
            case .site(let url, _):
                guard sites.insert(stripped(url)).inserted else { return nil }
                return candidate
            }
        }.prefix(20))
    }

    /// A NAVIGATION result's address, when it is a public web page: http or
    /// https, a dotted host, no name, password or port. Asked over https,
    /// as a site typed into the field is.
    nonisolated static func site(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 2048, var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host?.lowercased(), host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        parts.scheme = "https"
        parts.host = host
        return parts.url
    }

    /// Only EntityInfo's display name (protobuf field 7). Provider links,
    /// actions and image addresses are never interpreted.
    nonisolated private static func entityName(_ encoded: String) -> String? {
        guard let data = Data(base64Encoded: encoded), data.count <= 64_000 else { return nil }
        let bytes = Array(data)
        var at = 0
        func integer() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard at < bytes.count else { return nil }
                let byte = bytes[at]; at += 1
                if shift == 63, byte > 1 { return nil }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            return nil
        }
        while at < bytes.count {
            guard let tag = integer(), tag >> 3 != 0 else { return nil }
            switch tag & 7 {
            case 0: guard integer() != nil else { return nil }
            case 1: guard bytes.count - at >= 8 else { return nil }; at += 8
            case 2:
                guard let length = integer(), length <= UInt64(bytes.count - at) else { return nil }
                let end = at + Int(length)
                if tag >> 3 == 7 { return String(bytes: bytes[at..<end], encoding: .utf8) }
                at = end
            case 5: guard bytes.count - at >= 4 else { return nil }; at += 4
            default: return nil
            }
        }
        return nil
    }
}

extension SearchSuggestions {
    /// As many of the engine's completions as Arc lists under its command
    /// bar: a few, never a page of them over everything else.
    static let shown = 4
    /// Places you have been, or have open, that the words name: listed
    /// before the completions, as Arc and Chrome list them. Any more of
    /// them follow the completions.
    static let placesFirst = 3

    /// The engine's completions put into the field's list: under the words
    /// themselves and the Ask and Task rows that stay right under them, and
    /// under the first few pages the words name. The row Return takes stays
    /// the one it was.
    static func merge(_ suggested: [Suggestion], into list: [Suggestion], lead: Int?) -> (list: [Suggestion], lead: Int?) {
        // A site the engine names that a row already goes to (the same
        // address: a page you have been to, have open or keep) is listed
        // once, there, as Chromium's AutocompleteResult keeps one match for
        // a destination (its stripped URL).
        let listed = Set(list.compactMap { $0.url.map(stripped) })
        let suggested = suggested.filter { !$0.engine || !($0.url.map { listed.contains(stripped($0)) } ?? false) }
        guard !suggested.isEmpty, list.contains(where: { $0.kind == .search }) else { return (list, lead) }
        let leading = lead.flatMap { list.indices.contains($0) ? list[$0].id : nil }
        let words = Set(suggested.filter { !$0.engine }.map { $0.key.lowercased() })
        var list = list.filter { !($0.kind == .asked && words.contains($0.key.lowercased())) }
        guard let block = list.lastIndex(where: \.isUnderWords) else { return (list, lead) }
        var at = block + 1
        var places = 0
        // Open tabs, another space's under the places too, all come before
        // the completions: going back beats searching again (#260a).
        while at < list.count {
            if list[at].kind == .open || list[at].bookmarked {
                at += 1
            } else if places < placesFirst, [.visited, .known].contains(list[at].kind) {
                at += 1
                places += 1
            } else {
                break
            }
        }
        // Actions can stand between the words and a saved destination.
        // They must not let web completions jump ahead of that destination.
        if let kept = list.lastIndex(where: { $0.kind == .open || $0.bookmarked }) {
            at = max(at, kept + 1)
        }
        // A site the engine names goes under its words, as Chromium 157
        // lists its navigation suggestion after the search suggestions.
        let searched = suggested.filter { !$0.engine }.prefix(shown)
        list.insert(contentsOf: Array(searched) + suggested.filter(\.engine), at: at)
        return (list, leading.flatMap { id in list.firstIndex { $0.id == id } })
    }

    /// One destination however it is written, as Chromium's
    /// AutocompleteMatch::GURLToStrippedGURL has it: no scheme, no www., no
    /// fragment; "/" for no path; the query kept.
    nonisolated static func stripped(_ url: URL) -> String {
        guard var host = url.host()?.lowercased(), !host.isEmpty else { return url.absoluteString }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path(percentEncoded: true)
        return host + port + (path.isEmpty ? "/" : path) + (url.query(percentEncoded: true).map { "?" + $0 } ?? "")
    }

    /// The engine's answer as the field's rows: words as searches, a site
    /// as a site's row (its icon, address and title, as a page you have
    /// been to is drawn), never the row Return takes. Chrome neither makes
    /// it the default match nor finishes its address inline.
    static func rows(_ items: [Item], search: (String) -> URL?) -> [Suggestion] {
        items.compactMap { item in
            switch item {
            case .words(let words):
                return search(words).map { Suggestion(key: words, title: "", url: $0, kind: .suggested) }
            case .site(let url, let title):
                return Suggestion(key: History.key(for: url), title: title, url: url, kind: .known, engine: true)
            }
        }
    }
}
