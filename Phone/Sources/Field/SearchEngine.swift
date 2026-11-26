import Foundation

/// The engines already supported by the Mac. No request is made until Search.
enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
    case google, duckduckgo, bing, ecosia, startpage, kagi, brave, qwant, custom
    static let standard = SearchEngine.google
    static let key = "search.engine"
    static let customKey = "search.custom"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .google: "Google"
        case .duckduckgo: "DuckDuckGo"
        case .bing: "Bing"
        case .ecosia: "Ecosia"
        case .startpage: "Startpage"
        case .kagi: "Kagi"
        case .brave: "Brave Search"
        case .qwant: "Qwant"
        case .custom: "Other…"
        }
    }
    private var template: String {
        switch self {
        case .google: "https://www.google.com/search?q=%s"
        case .duckduckgo: "https://duckduckgo.com/?q=%s"
        case .bing: "https://www.bing.com/search?q=%s"
        case .ecosia: "https://www.ecosia.org/search?q=%s"
        case .startpage: "https://www.startpage.com/sp/search?query=%s"
        case .kagi: "https://kagi.com/search?q=%s"
        case .brave: "https://search.brave.com/search?q=%s"
        case .qwant: "https://www.qwant.com/?q=%s"
        case .custom: ""
        }
    }

    /// Show the words of a Google results page when its address is edited.
    static func googleWords(in url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil,
              let host = parts.host?.lowercased(), parts.path == "/search" else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard bare.range(of: #"^google\.(com|[a-z]{2}|(?:co|com)\.[a-z]{2})$"#, options: .regularExpression) != nil else { return nil }
        // Decode form spaces before percent escapes, so C%2B%2B stays C++.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        let queries = (parts.queryItems ?? []).filter { $0.name == "q" }
        guard queries.count == 1, let words = queries.first?.value,
              !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return words
    }

    /// Search words may vary the path, query and fragment, never the origin or credentials.
    static func accepts(_ template: String) -> Bool { host(of: template) != nil }
    private static func host(of template: String) -> String? {
        let value = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains("%s"),
              let a = URLComponents(string: value.replacingOccurrences(of: "%s", with: "a")),
              let b = URLComponents(string: value.replacingOccurrences(of: "%s", with: "b")),
              let scheme = a.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = a.host, !host.isEmpty, host == b.host, scheme == b.scheme?.lowercased(),
              a.port == b.port, a.user == b.user, a.password == b.password,
              a.url != nil, b.url != nil else { return nil }
        return host.lowercased()
    }

    struct Selection: Equatable, Sendable {
        let requested: String?
        let customTemplate: String
        static let standard = Selection(rawValue: nil)
        init(rawValue: String?, customTemplate: String = "") {
            requested = rawValue
            self.customTemplate = customTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var engine: SearchEngine {
            guard let requested, let selected = SearchEngine(rawValue: requested) else { return .standard }
            return selected == .custom && !SearchEngine.accepts(customTemplate) ? .standard : selected
        }
        var name: String {
            guard engine == .custom, let host = SearchEngine.host(of: customTemplate) else { return engine.title }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        var fallbackNote: String? {
            guard let requested else { return nil }
            if SearchEngine(rawValue: requested) == nil {
                return "This search engine isn't supported on this \(DeviceWord.name). Searches use Google; choose an engine below."
            }
            if requested == SearchEngine.custom.rawValue && !SearchEngine.accepts(customTemplate) {
                return "Your Mac's custom search address isn't valid. Searches use Google; choose an engine below."
            }
            return nil
        }
        func url(for text: String) -> URL? {
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let template = engine == .custom ? customTemplate : engine.template
            guard !words.isEmpty,
                  let escaped = words.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
            // Replace only the original placeholders. A marker could overwrite
            // a literal already present in the person's custom address.
            return URL(string: template.components(separatedBy: "%s").joined(separator: escaped))
        }
    }
}
