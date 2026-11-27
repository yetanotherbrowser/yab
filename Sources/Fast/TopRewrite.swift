import Foundation

/// What both engines decide of a tab's top document before it loads
/// (Shield.redirect): whether the tracking names a copy drops may go, and
/// the rewrites in a row, which end at `cap` so a site that sends the tab
/// back for its tracking name gets it, and the address loads as it is.
@MainActor
struct TopRewrite {
    static let cap = 4

    struct Navigation {
        var url: URL
        var method: String? = "GET"
        var kind: PageAction.Kind = .other
        /// A server's redirect: a hop of the navigation before.
        var redirect = false
        /// Yab's own load: typed, a bookmark, handed over by another app.
        var byYab = false
        /// A click or a press, for the engine routing a person's navigation.
        var byPerson = false
        /// The engine rewrites the held request (Chromium); WebKit loads anew.
        var inPlace = false
        var keepsOpener = false
        /// The address shown now.
        var shown: URL?
        /// The address of the frame that asked.
        var source: URL?
    }

    struct Step: Equatable {
        /// Where the navigation goes instead; nil, as it is.
        var instead: URL?
        /// A person's, counting the load of a rewrite of one.
        var byPerson: Bool
    }

    private(set) var count = 0
    private var last: URL?
    private var lastByPerson = false
    private var yabChain = false

    static func cleans(_ navigation: Navigation) -> Bool {
        let kind = navigation.kind
        guard kind != .backForward, kind != .reload, kind != .formResubmitted, !navigation.keepsOpener,
              !Browser.sameDocument(navigation.url, navigation.shown) else { return false }
        if navigation.inPlace { return true }
        if navigation.byYab { return true }
        // A load anew adds an entry: a page's own script navigation (location.replace) keeps its own.
        guard kind == .linkActivated || kind == .formSubmitted || navigation.redirect else { return false }
        // A load anew reaches the site as no site's (Sec-Fetch-Site: none), so another site's request stays native.
        // WebKit's source frame can still name the page before, so the page shown has to be same-site too.
        let site = SiteProcesses.site(of: navigation.url)
        return [navigation.source, navigation.shown].allSatisfy { $0.map { SiteProcesses.site(of: $0) == site } ?? true }
    }

    /// The address Yab sent (Tab.engineSent) as the engine asks for it: "https://a.example?q" is "https://a.example/?q".
    nonisolated static func sameAddress(_ url: URL, _ sent: URL?) -> Bool {
        guard let sent else { return false }
        func plain(_ url: URL) -> String? {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            parts.scheme = parts.scheme?.lowercased()
            parts.percentEncodedHost = parts.percentEncodedHost?.lowercased()
            if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
            return parts.string
        }
        return url == sent || (plain(url) != nil && plain(url) == plain(sent))
    }

    /// `redirect` is Shield.redirect for the address, with whether it may clean.
    mutating func next(_ navigation: Navigation, _ redirect: (URL, Bool) -> URL?) -> Step {
        let ours = last != nil && navigation.url == last
        let byPerson = navigation.byPerson || (ours && lastByPerson)
        if !ours && !navigation.redirect {
            count = 0
            yabChain = navigation.byYab
        }
        // The load of a rewrite, and the hops of Yab's own load, are Yab's.
        if ours { yabChain = true }
        var asked = navigation
        asked.byYab = navigation.byYab || ours || (navigation.redirect && yabChain)
        last = nil
        guard (navigation.method ?? "GET").uppercased() == "GET", count < Self.cap,
              let instead = redirect(navigation.url, Self.cleans(asked)) else { return Step(instead: nil, byPerson: byPerson) }
        count += 1
        last = instead
        lastByPerson = byPerson
        return Step(instead: instead, byPerson: byPerson)
    }
}
