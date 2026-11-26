import UIKit
import WebKit

/// A page's files: a load or a link that becomes a download, the page put
/// back as it was, and the transfer adopted, asked about and retried.
extension WebPool {
    struct DownloadOrigin {
        let requestURL: URL
        let frameURL: URL?
        let url: URL?
        let document: UUID?
        let store: ObjectIdentifier
        let privateSession: UUID?
    }
    struct DownloadConversion {
        let origin: DownloadOrigin
        let document: UUID?
        let navigation: WKNavigation?
        /// A document the tab was opening, for the system's viewer (PageDocument).
        var opens = false
    }

    /// Where a main-frame load or a file the page asked for comes from, while
    /// the tab may still interact: a file later binds to it.
    func noteDownloadOrigin(_ id: Tab.ID, of url: URL, for action: WKNavigationAction, in webView: WKWebView) {
        downloadOrigins[id] = canInteract(id, in: webView) ? DownloadOrigin(requestURL: url, frameURL: action.sourceFrame.request.url, url: committedURLs[id] ?? webView.url,
            document: documents[id], store: ObjectIdentifier(webView.configuration.websiteDataStore),
            privateSession: privateTabs.contains(id) ? privateSession : nil) : nil
    }

    /// A file the page itself asked for: from its main frame only.
    func downloadPolicy(_ id: Tab.ID?, for action: WKNavigationAction, in webView: WKWebView) -> WKNavigationActionPolicy {
        guard !fixturesEnabled, let id, canInteract(id, in: webView), action.sourceFrame.isMainFrame,
              let origin = downloadOrigins[id] else { return .cancel }
        downloadConversions[id] = DownloadConversion(origin: origin, document: documents[id], navigation: activeNavigations[id])
        return .download
    }

    /// A response the tab can't show, or a document for the system's viewer,
    /// becomes a file; anything else loads.
    func downloadPolicy(for response: WKNavigationResponse, in webView: WKWebView) -> WKNavigationResponsePolicy {
        let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("attachment") == true
        // A PDF or another document opens as a file, in the system's viewer,
        // which saves and shares it; WebKit's own view of it has neither.
        // A site told no doesn't send files: its documents stay WebKit's own view.
        let opens = !attachment && response.isForMainFrame && PageDocument.opensInViewer(response.response.mimeType)
            && !downloadsTurnedOff(tabsByView[ObjectIdentifier(webView)], file: response.response.url)
        guard attachment || opens || !response.canShowMIMEType else { return .allow }
        guard !fixturesEnabled, response.isForMainFrame, let id = tabsByView[ObjectIdentifier(webView)],
              canInteract(id, in: webView), downloadOrigins[id] != nil else {
            // A tab out of sight never opens the viewer over another: it shows
            // the document as WebKit does.
            if opens { return .allow }
            if response.isForMainFrame, let id = tabsByView[ObjectIdentifier(webView)] { restoreDownloadSource(id, in: webView) }
            return .cancel
        }
        if let origin = downloadOrigins[id] {
            downloadConversions[id] = DownloadConversion(origin: origin, document: documents[id], navigation: activeNavigations[id], opens: opens)
        }
        return .download
    }

    /// The site the file would be asked about (adopt's source host) said no
    /// to downloads. A private tab remembers no answer, so it never has.
    private func downloadsTurnedOff(_ id: Tab.ID?, file: URL?) -> Bool {
        guard let id, let siteSettings else { return false }
        let page = committedURLs[id] == nil ? nil : downloadOrigins[id]?.url
        let site = siteOf?(id, page)
        if site?.isPrivate ?? privateTabs.contains(id) { return false }
        let host = site?.host ?? page?.host() ?? file?.host()
        return siteSettings.decision(.downloads, for: host, isPrivate: false) == .off
    }

    /// A file never becomes a phantom page/history entry. WebKit retains the
    /// source document; verify its committed URL/store before restoring its painted state.
    /// During a native conversion, WKWebView.url can still expose an earlier
    /// traversal item. The captured frame, document and navigation bind the
    /// conversion; the pool's qualified committed URL binds its source.
    @discardableResult
    private func restoreDownloadSource(_ id: Tab.ID, in view: WKWebView) -> DownloadOrigin? {
        guard live[id] === view, let origin = downloadOrigins.removeValue(forKey: id),
              origin.store == ObjectIdentifier(view.configuration.websiteDataStore),
              origin.privateSession == (privateTabs.contains(id) ? privateSession : nil),
              let sourceURL = origin.url, committedURLs[id] == sourceURL else { return nil }
        if let active = activeNavigations.removeValue(forKey: id) { retiredNavigations.add(active) }
        documents[id] = origin.document ?? UUID()
        requestedURLs[id] = nil; actionTypes[id] = nil; pendingIndex[id] = nil
        endRefresh(id, in: view)
        publishState(id)
        if origin.url != nil { waitForPaint(id, in: view) }
        return origin
    }

    func becameDownload(_ download: WKDownload, from view: WKWebView) {
        guard let id = tabsByView[ObjectIdentifier(view)], let conversion = downloadConversions[id],
              documents[id] == conversion.document, activeNavigations[id] === conversion.navigation,
              download.originalRequest?.url == conversion.origin.requestURL,
              download.originatingFrame.request.url == conversion.origin.frameURL,
              download.originatingFrame.isMainFrame, case let fresh = committedURLs[id] == nil,
              // A new window's first load is its opener's: WebKit names the opener's view.
              download.webView === view || fresh && download.webView === popupOpeners[id].flatMap({ live[$0] }),
              let origin = fresh ? releaseFreshSource(id, in: view) : restoreDownloadSource(id, in: view) else { download.cancel(nil); return }
        downloadConversions[id] = nil
        let opener = fresh ? popupOpeners.removeValue(forKey: id) : nil
        presentDownload(download, tab: id, viewer: opener ?? id, in: view, origin: origin, opens: conversion.opens)
        // A page's new window that was only ever this file has nothing to
        // show: it goes, as window.close() would, back to its opener, and
        // the document is shown for the opener.
        if let opener {
            onCloseWindowFrom?(id, opener)
            forget(id)
        }
    }

    /// A tab that had shown nothing yet when its first load became a file:
    /// no page to put back, only the load to end.
    private func releaseFreshSource(_ id: Tab.ID, in view: WKWebView) -> DownloadOrigin? {
        guard live[id] === view, committedURLs[id] == nil, let origin = downloadOrigins[id],
              origin.store == ObjectIdentifier(view.configuration.websiteDataStore),
              origin.privateSession == (privateTabs.contains(id) ? privateSession : nil) else { return nil }
        downloadOrigins[id] = nil
        if let active = activeNavigations.removeValue(forKey: id) { retiredNavigations.add(active) }
        requestedURLs[id] = nil; actionTypes[id] = nil; pendingIndex[id] = nil
        endRefresh(id, in: view)
        publishState(id)
        return origin
    }

    private func presentDownload(_ download: WKDownload, tab id: Tab.ID, viewer: Tab.ID, in view: WKWebView, origin: DownloadOrigin, opens: Bool) {
        guard canInteract(id, in: view) else { download.cancel(nil); return }
        let page = committedURLs[id] == nil ? nil : origin.url
        adopt(download, source: downloadSource(id, page: page, file: download.originalRequest?.url), page: page, opens: opens, viewer: viewer)
    }

    /// Where a file comes from, read while its tab is here: a tab gone by
    /// the time WebKit hands the file over, or by Retry, reads as public.
    private func downloadSource(_ id: Tab.ID, page: URL?, file: URL?) -> PageDownload.Source {
        let site = siteOf?(id, page)
        return PageDownload.Source(tab: id, host: site?.host ?? page?.host() ?? file?.host() ?? "",
                                   isPrivate: site?.isPrivate ?? privateTabs.contains(id))
    }

    /// The WKDownload is ours from here, under the source its page gave.
    /// A document is shown for `viewer` once whole.
    private func adopt(_ download: WKDownload, source: PageDownload.Source, page: URL?, entry: UUID? = nil, from: CGPoint? = nil,
                       opens: Bool = false, viewer: Tab.ID? = nil) {
        let id = source.tab
        let job = PageDownload(download: download, source: source, store: downloads, entry: entry, from: from, opens: opens,
            ask: { [weak self] question, answer in
                guard let ask = self?.onDownloadAsk else { answer(true); return }
                ask(question, answer)
            },
            retry: { [weak self] entry, store, request in
                self?.retryDownload(entry, store, request, source: source, page: page) ?? false
            }, ended: { [weak self] token in self?.transfers[token] = nil },
            viewed: { [weak self] entry in self?.onViewDownload?(viewer ?? id, entry) })
        transfers[job.id] = job
        if appAway { job.leave() }
    }

    /// Download Linked File: the link's bytes through the tab's own store,
    /// the page where it is.
    /// The file flies from where its link was held, when that is fresh.
    func downloadLinked(_ url: URL, from id: Tab.ID) {
        let held = heldLink.flatMap { $0.tab == id && ProcessInfo.processInfo.systemUptime - $0.time < PageLinkMenu.heldFreshness ? $0.at : nil }
        heldLink = nil
        startDownload(url, from: id, flyingFrom: held)
    }

    /// `flyingFrom`: where the disc lifts off, in the window; nil, the
    /// downloads button only gives.
    private func startDownload(_ url: URL, from id: Tab.ID, flyingFrom held: CGPoint?) {
        guard let view = live[id], canInteract(id, in: view), allowsDownloadOf(url) else { return }
        let page = committedURLs[id] ?? view.url
        let source = downloadSource(id, page: page, file: url)
        view.startDownload(using: URLRequest(url: url)) { [weak self] download in
            self?.adopt(download, source: source, page: page, from: held)
        }
    }

    /// The type of the document a main-frame response loads, kept until
    /// that load commits.
    func noteDocumentType(_ response: WKNavigationResponse, loads: Bool, in webView: WKWebView) {
        guard response.isForMainFrame, let id = tabsByView[ObjectIdentifier(webView)] else { return }
        respondedTypes[id] = loads ? (response.response.url, response.response.mimeType) : nil
    }

    /// A commit names its page's type from the response for that very
    /// address. A page back from WebKit's back-forward cache brings none:
    /// its type is the one its address had in the tab's history.
    /// A page a POST answered is no file Download can ask for again: a GET
    /// to its address can answer with something else.
    func commitDocumentType(_ id: Tab.ID, at url: URL?, in view: WKWebView) {
        let responded = respondedTypes.removeValue(forKey: id)
        let fetched = requestMethods.removeValue(forKey: id) == "GET"
        var known = historyTypes[id] ?? [:]
        if let url, let responded, responded.url == url { known[url] = responded.type }
        // Only what the tab's history still holds.
        let list = view.backForwardList
        let held = Set(([list.currentItem].compactMap { $0 } + list.backList + list.forwardList).map(\.url) + [url].compactMap { $0 })
        known = known.filter { held.contains($0.key) }
        historyTypes[id] = known.isEmpty ? nil : known
        documentTypes[id] = fetched ? url.flatMap { known[$0] } : nil
    }

    /// The page is a file WebKit shows, at an address Download can ask again:
    /// a blob: or data: document is out of its reach, and so is a POST's answer.
    func documentDownloadable(_ id: Tab.ID) -> Bool {
        PageDocument.offersDownload(documentTypes[id]) && committedURLs[id].map(allowsDownloadOf) == true
    }

    /// Download, for a page that is a picture, a sound or text: its address
    /// asked again as a linked file, through the tab's own store and cookies,
    /// with the page and its history left where they are. No link was held
    /// for it: a hold left on the page is its link's, not this file's.
    func downloadDocument(of id: Tab.ID) {
        guard documentDownloadable(id), let url = committedURLs[id] else { return }
        startDownload(url, from: id, flyingFrom: nil)
    }

    func allowsDownloadOf(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }

    /// Retry, under its row and its first source, in the store it first read:
    /// from its tab if it is still there, else from any page of that store.
    private func retryDownload(_ entry: UUID, _ store: WKWebsiteDataStore?, _ request: URLRequest,
                               source: PageDownload.Source, page: URL?) -> Bool {
        guard let store else { return false }
        let view = live[source.tab].flatMap { $0.configuration.websiteDataStore === store ? $0 : nil }
            ?? live.values.first { $0.configuration.websiteDataStore === store }
        guard let view else { return false }
        view.startDownload(using: request) { [weak self] download in
            self?.adopt(download, source: source, page: page, entry: entry)
        }
        return true
    }

    /// Where a link is held, for Download Linked File to fly from.
    func noteHeldLink(_ id: Tab.ID, in webView: WKWebView) {
        if let at = PageLinkMenu.pressPoint(in: webView) { heldLink = (id, at, ProcessInfo.processInfo.systemUptime) }
    }
}
