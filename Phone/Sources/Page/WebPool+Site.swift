import Security
import UIKit
import WebKit

/// The page menu's and Site Settings' work on a live page: zoom and desktop
/// mode remembered per site, iOS's own find bar, the field's match count,
/// the connection, and clearing a site's data.
extension WebPool {
    private func site(_ id: Tab.ID, url: URL?) -> (host: String?, isPrivate: Bool) {
        siteOf?(id, url) ?? (url?.host(), false)
    }

    // MARK: - zoom and desktop

    /// The site's remembered zoom, on the page now (a commit, a change).
    func applyZoom(_ id: Tab.ID, in view: WKWebView? = nil) {
        guard let view = view ?? liveView(id), let siteSettings else { return }
        let site = site(id, url: view.url)
        let zoom = CGFloat(siteSettings.zoom(site.host, isPrivate: site.isPrivate))
        if abs(view.pageZoom - zoom) > 0.001 { view.pageZoom = zoom }
    }

    func desktop(_ id: Tab.ID, url: URL?) -> Bool {
        guard let siteSettings else { return false }
        let site = site(id, url: url)
        return siteSettings.desktop(site.host, isPrivate: site.isPrivate)
    }

    func contentMode(_ id: Tab.ID, url: URL?) -> WKWebpagePreferences.ContentMode {
        guard let siteSettings else { return Self.defaultContentMode }
        let site = site(id, url: url)
        return siteSettings.contentMode(site.host, isPrivate: site.isPrivate)
    }

    /// Before any site is known, as Safari: desktop on an iPad, mobile on an iPhone.
    static var defaultContentMode: WKWebpagePreferences.ContentMode {
        UIDevice.current.userInterfaceIdiom == .pad ? .recommended : .mobile
    }

    // MARK: - find on page

    /// iOS's find bar over the page, with `text` in it if given.
    @discardableResult
    func presentFind(_ id: Tab.ID, text: String? = nil) -> Bool {
        guard let view = liveView(id), let find = view.findInteraction else { return false }
        if let text, !text.isEmpty { find.searchText = text }
        find.presentFindNavigator(showingReplace: false)
        return true
    }

    /// The find bar is up over this tab's page.
    func isFinding(_ id: Tab.ID) -> Bool { liveView(id)?.findInteraction?.isFindNavigatorVisible == true }

    func dismissFind(_ id: Tab.ID) { liveView(id)?.findInteraction?.dismissFindNavigator() }

    /// How many times the page's visible text holds `text`, case and accents
    /// aside, the count "On This Page" shows. Read in Reader's isolated world:
    /// the page's own scripts never see the words.
    func matches(of text: String, in id: Tab.ID) async -> Int {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.count >= 2, let view = liveView(id), !view.isLoading else { return 0 }
        let script = """
        const body = document.body; if (!body) return 0;
        const norm = s => s.normalize('NFD').replace(/[\\u0300-\\u036f]/g, '').toLocaleLowerCase();
        const hay = norm(body.innerText || ''), needle = norm(words);
        if (!needle) return 0;
        let n = 0, i = hay.indexOf(needle);
        while (i !== -1 && n < 1000) { n++; i = hay.indexOf(needle, i + needle.length); }
        return n;
        """
        let result: Any? = await withCheckedContinuation { continuation in
            view.callAsyncJavaScript(script, arguments: ["words": words], in: nil, in: PageReader.world) { result in
                continuation.resume(returning: try? result.get())
            }
        }
        return (result as? NSNumber)?.intValue ?? 0
    }

    // MARK: - the connection

    struct Connection: Equatable {
        var secure: Bool
        /// Who the certificate names, who vouches for it, until when.
        var subject: String?
        var issuer: String?
        var expires: Date?
    }

    func connection(_ id: Tab.ID, fallback url: URL?) -> Connection {
        guard let view = liveView(id), let url = view.url, ["http", "https"].contains(url.scheme ?? "") else {
            return Connection(secure: url?.scheme == "https")
        }
        guard url.scheme == "https", view.hasOnlySecureContent else { return Connection(secure: false) }
        var connection = Connection(secure: true)
        if let trust = view.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
            connection.subject = SecCertificateCopySubjectSummary(leaf) as String?
            if chain.count > 1 { connection.issuer = SecCertificateCopySubjectSummary(chain[1]) as String? }
            connection.expires = SecCertificateCopyNotValidAfterDate(leaf) as Date?
        }
        return connection
    }

    // MARK: - data

    /// Everything the site keeps in the tab's own store (cookies too), then
    /// the page again.
    func clearData(_ id: Tab.ID, host: String) async {
        guard let view = liveView(id) else { return }
        let store = view.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let site = host.lowercased()
        let mine = records.filter { record in
            let name = record.displayName.lowercased()
            return name == site || name.hasSuffix("." + site) || site.hasSuffix("." + name)
        }
        await store.removeData(ofTypes: types, for: mine)
        reload(id)
    }
}
