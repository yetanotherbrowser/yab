import AppKit
import PDFKit
import WebKit

// "Put these 5 tabs in one PDF for the flight, no ads": save_page with tabs
// and reader (docs/agent-asks.md). Each page is printed on its own, then
// they are joined, an outline entry an article, so Preview's sidebar lists
// them. With reader, a page is first cut down to its article (the prose and
// its pictures, no menus, rails, comments or ads) and that is laid out in a
// page of Yab's own, out of sight, with no scripts, and printed from there.

extension PageSave {
    /// Tabs (or one in reading form) as one PDF in `folder`.
    static func book(_ tabs: [Tab], reader: Bool, title: String?, in folder: URL,
                     done: @escaping @MainActor (Result<URL, Error>) -> Void) {
        guard let first = tabs.first else { return done(.failure(Failure("No tabs to save"))) }
        let name = title.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? (tabs.count == 1 ? first.title : "\(first.title) and \(tabs.count - 1) more")
        let file = Self.file(title: name, host: first.address?.host() ?? "", format: "pdf", in: folder)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("yab-book-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var parts: [(title: String, file: URL)] = []
        func next(_ index: Int) {
            guard index < tabs.count else {
                do {
                    try join(parts, into: file)
                    done(.success(file))
                } catch { done(.failure(error)) }
                try? FileManager.default.removeItem(at: scratch)
                return
            }
            let tab = tabs[index]
            let part = scratch.appendingPathComponent("\(index).pdf")
            let landed: @MainActor (Result<URL, Error>) -> Void = { result in
                switch result {
                case .success(let url): parts.append((tab.title.isEmpty ? tab.address?.host() ?? "Page" : tab.title, url)); next(index + 1)
                case .failure(let error): done(.failure(Failure("Couldn’t save \(tab.title.isEmpty ? "a tab" : tab.title): \(error.localizedDescription)")))
                }
            }
            if reader { article(tab, to: part, done: landed) } else { pdfPage(tab.page, to: part, done: landed) }
        }
        next(0)
    }

    /// Whether `count` tabs saved as `format` are joined into one file:
    /// Markdown or text, and more than one tab. One tab is saved as itself.
    nonisolated static func joinsTabs(format: String, count: Int) -> Bool {
        (format == "md" || format == "txt") && count > 1
    }

    /// Tabs' Markdown or text one after another in one file, a rule between.
    static func joined(_ tabs: [Tab], as format: String, title: String?, in folder: URL,
                       done: @escaping @MainActor (Result<URL, Error>) -> Void) {
        guard let first = tabs.first else { return done(.failure(Failure("No tabs to save"))) }
        let name = title.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? (tabs.count == 1 ? first.title : "\(first.title) and \(tabs.count - 1) more")
        collectJoined(count: tabs.count, read: { index, reply in
            AgentPage.run(tabs[index], format == "md" ? markdown : text) { reply($0) }
        }) { result in
            switch result {
            case .failure(let error):
                done(.failure(error))
            case .success(let pieces):
                let file = Self.file(title: name, host: first.address?.host() ?? "", format: format, in: folder)
                do {
                    try Data(pieces.joined(separator: format == "md" ? "\n\n---\n\n" : "\n\n\n").utf8).write(to: file)
                    done(.success(file))
                } catch { done(.failure(error)) }
            }
        }
    }

    /// A joined file is complete only when every requested page was read.
    /// The first failed or empty page ends it, without a partial success.
    static func collectJoined(
        count: Int,
        read: @escaping @MainActor (Int, @escaping @MainActor (Result<Any?, Error>) -> Void) -> Void,
        done: @escaping @MainActor (Result<[String], Error>) -> Void
    ) {
        guard count > 0 else { return done(.failure(Failure("No tabs to save"))) }
        var pieces: [String] = []
        var expected = 0
        var ended = false
        func next(_ index: Int) {
            guard !ended else { return }
            guard index < count else {
                ended = true
                done(.success(pieces))
                return
            }
            read(index) { result in
                // The reply belongs only to the page currently requested.
                guard !ended, expected == index else { return }
                expected += 1
                switch result {
                case .failure(let error):
                    ended = true
                    done(.failure(error))
                case .success(let value):
                    guard let words = value as? String,
                          !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        ended = true
                        done(.failure(Failure("The page gave nothing to save")))
                        return
                    }
                    pieces.append(words.trimmingCharacters(in: .whitespacesAndNewlines))
                    next(index + 1)
                }
            }
        }
        next(0)
    }

    /// PDFs one after another, an outline entry at each one's first page.
    nonisolated static func join(_ parts: [(title: String, file: URL)], into file: URL) throws {
        let book = PDFDocument()
        let outline = PDFOutline()
        for part in parts {
            guard let document = PDFDocument(url: part.file), document.pageCount > 0 else { throw Failure("A page came out empty") }
            let start = book.pageCount
            for index in 0..<document.pageCount {
                if let page = document.page(at: index) { book.insert(page, at: book.pageCount) }
            }
            if let page = book.page(at: start) {
                let entry = PDFOutline()
                entry.label = part.title
                entry.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .mediaBox).height))
                outline.insertChild(entry, at: outline.numberOfChildren)
            }
        }
        if parts.count > 1 { book.outlineRoot = outline }
        guard book.write(to: file) else { throw Failure("Couldn’t write the PDF") }
    }

    // MARK: - reading form

    /// The tab's article laid out on its own and printed.
    static func article(_ tab: Tab, to file: URL, done: @escaping @MainActor (Result<URL, Error>) -> Void) {
        AgentPage.run(tab, readArticle) { result in
            guard case .success(let value) = result, let got = value as? [String: Any],
                  let body = got["html"] as? String, !body.isEmpty else {
                // No article to find: the page as it is.
                return pdfPage(tab.page, to: file, done: done)
            }
            let page = articlePage(title: got["title"] as? String ?? tab.title, byline: got["byline"] as? String ?? "",
                                   site: got["site"] as? String ?? "", url: got["url"] as? String ?? "", body: body)
            OffscreenPage.print(page, base: tab.address, to: file, done: done)
        }
    }

    /// The article as a page of its own, set for reading on paper.
    nonisolated static func articlePage(title: String, byline: String, site: String, url: String, body: String) -> String {
        let head = [byline, site].filter { !$0.isEmpty }.joined(separator: " · ")
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        html { -webkit-print-color-adjust: exact; background: #fff; }
        body { font: 14.5px/1.6 "New York", "Iowan Old Style", Georgia, serif; color: #1a1a1a; margin: 0; padding: 0; }
        h1.title { font: 600 29px/1.2 -apple-system, "Helvetica Neue", sans-serif; margin: 0 0 8px; }
        p.from { font: 12.5px/1.4 -apple-system, "Helvetica Neue", sans-serif; color: #666; margin: 0 0 24px; }
        h1, h2, h3, h4 { font-family: -apple-system, "Helvetica Neue", sans-serif; line-height: 1.25; break-after: avoid; }
        img, figure, video, picture { max-width: 100%; height: auto; break-inside: avoid; }
        figure { margin: 16px 0; } figcaption { font-size: 12.5px; color: #666; }
        pre, code { font: 12.5px/1.45 "SF Mono", Menlo, monospace; white-space: pre-wrap; }
        pre { background: #f4f4f4; padding: 10px; border-radius: 5px; break-inside: avoid; }
        blockquote { margin: 16px 0; padding-left: 16px; border-left: 3px solid #ccc; color: #444; }
        a { color: inherit; text-decoration: underline; text-decoration-color: #aaa; }
        table { border-collapse: collapse; font-size: 13px; } td, th { border: 1px solid #ccc; padding: 4px 7px; }
        </style></head><body>
        <h1 class="title">\(escape(title))</h1>
        <p class="from">\(escape(head))\(head.isEmpty ? "" : "<br>")\(escape(url))</p>
        \(body)
        </body></html>
        """
    }

    /// The page's article: the one element holding most of its prose,
    /// cloned with what is around it taken out, its pictures and links
    /// made absolute. Nil html when there is no article to speak of.
    static let readArticle = """
    const AROUND = /(^|\\s|-|_)(comments?|sidebar|related|recommend\\w*|footer|promo|newsletter|share|social|advert\\w*|sponsor\\w*|ad|ads|banner|subscribe|paywall|cookie)(\\s|-|_|$)/i;
    const around = (el) => {
      for (let up = el; up && up !== document.body; up = up.parentElement) {
        if (/^(ASIDE|NAV|FOOTER|FORM|DIALOG)$/.test(up.tagName)) return true;
        const role = up.getAttribute('role');
        if (role === 'complementary' || role === 'navigation' || role === 'dialog') return true;
        const name = (typeof up.className === 'string' ? up.className : '') + ' ' + (up.id || '');
        if (name.length > 1 && AROUND.test(name)) return true;
      }
      return false;
    };
    const score = new Map();
    let total = 0;
    for (const p of document.querySelectorAll('p, pre, li')) {
      const n = p.textContent.trim().length;
      if (n < 40 || around(p)) continue;
      total += n;
      for (let up = p.parentElement, depth = 0; up && up !== document.documentElement && depth < 6; up = up.parentElement, depth++) {
        score.set(up, (score.get(up) || 0) + n);
      }
    }
    if (total < 400) return null;
    let best = null;
    for (const [el, n] of score) {
      if (n < total * 0.6) continue;
      if (!best || el.textContent.length < best.textContent.length) best = el;
    }
    best = best || document.querySelector('article') || document.querySelector('main') || document.body;
    const copy = best.cloneNode(true);
    copy.querySelectorAll('script, style, noscript, iframe, form, button, input, select, textarea, nav, aside, footer, dialog, svg, canvas, video, audio, [aria-hidden=true], [hidden]').forEach((el) => el.remove());
    copy.querySelectorAll('*').forEach((el) => {
      const name = (typeof el.className === 'string' ? el.className : '') + ' ' + (el.id || '');
      if (name.length > 1 && AROUND.test(name)) el.remove();
    });
    const abs = (u) => { try { return new URL(u, location.href).href; } catch (e) { return u; } };
    const originals = Array.from(best.querySelectorAll('img'));
    copy.querySelectorAll('img').forEach((img, i) => {
      const was = originals[i];
      const src = (was && was.currentSrc) || img.getAttribute('src') || img.getAttribute('data-src') || '';
      if (!src || src.startsWith('data:image/gif')) { img.remove(); return; }
      img.setAttribute('src', abs(src));
      img.removeAttribute('srcset'); img.removeAttribute('sizes'); img.removeAttribute('loading'); img.removeAttribute('style');
      img.removeAttribute('width'); img.removeAttribute('height');
    });
    copy.querySelectorAll('picture source').forEach((el) => el.remove());
    copy.querySelectorAll('a[href]').forEach((a) => a.setAttribute('href', abs(a.getAttribute('href'))));
    copy.querySelectorAll('[style]').forEach((el) => el.removeAttribute('style'));
    copy.querySelectorAll('h1').forEach((h, i) => { if (i === 0 && h.textContent.trim() === document.title.trim()) h.remove(); });
    const meta = (n) => { const m = document.querySelector('meta[name="' + n + '"], meta[property="' + n + '"]'); return m ? m.content : ''; };
    const title = meta('og:title') || (document.querySelector('h1') ? document.querySelector('h1').textContent.trim() : '') || document.title;
    return { title: title.replace(/\\s+/g, ' ').trim(), byline: meta('author'), site: meta('og:site_name') || location.hostname, url: location.href, html: copy.innerHTML };
    """
}

/// A page of Yab's own, laid out out of sight with no scripts, printed to
/// a PDF: an article in reading form.
@MainActor
final class OffscreenPage: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private var then: ((Bool) -> Void)?
    private var keep: OffscreenPage?

    private override init() {
        let config = WKWebViewConfiguration()
        config.processPool = Web.pool
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // 680 wide on Letter's 7 inches of type: 14.5 px reads as an 11 pt book.
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 680, height: 900), configuration: config)
        super.init()
        web.navigationDelegate = self
    }

    /// Letter's margin round the article, in points.
    static let margin: CGFloat = 54

    static func print(_ html: String, base: URL?, to file: URL, done: @escaping @MainActor (Result<URL, Error>) -> Void) {
        let page = OffscreenPage()
        page.keep = page
        page.then = { loaded in
            guard loaded else {
                page.keep = nil
                return done(.failure(PageSave.Failure("Couldn’t lay out the article")))
            }
            // Pictures come from the network: a moment for them, then cut.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { page.cut(to: file, done: done) }
        }
        page.web.loadHTMLString(html, baseURL: base)
        // A page that never finishes still prints what it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { page.finish(true) }
    }

    /// The page drawn whole, then cut into Letter pages between its lines.
    private func cut(to file: URL, done: @escaping @MainActor (Result<URL, Error>) -> Void) {
        web.evaluateJavaScript(Self.spans) { value, _ in
            MainActor.assumeIsolated {
                let got = value as? [String: Any] ?? [:]
                let height = CGFloat((got["height"] as? NSNumber)?.doubleValue ?? 0)
                let spans = (got["spans"] as? [[NSNumber]] ?? []).compactMap { $0.count == 2 ? (CGFloat($0[0].doubleValue), CGFloat($0[1].doubleValue)) : nil }
                self.web.createPDF { result in
                    MainActor.assumeIsolated {
                        self.keep = nil
                        guard case .success(let data) = result else {
                            if case .failure(let error) = result { done(.failure(error)) }
                            return
                        }
                        // The room a page has, in the article's own units.
                        let width = self.web.bounds.width
                        let room = (PageSave.sheet.height - 2 * Self.margin) * width / (PageSave.sheet.width - 2 * Self.margin)
                        let breaks = PageSave.breaks(spans: spans, height: height, room: room)
                        guard height > 0, let paged = PageSave.pages(data, breaks: breaks, height: height, margin: Self.margin) else {
                            return done(.failure(PageSave.Failure("Couldn’t make pages of the article")))
                        }
                        do { try paged.write(to: file); done(.success(file)) } catch { done(.failure(error)) }
                    }
                }
            }
        }
    }

    /// The document's height and every line of text and picture in it, top
    /// and bottom, for where a page may be cut.
    private static let spans = """
    (() => {
      const spans = [];
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      const range = document.createRange();
      while (walker.nextNode()) {
        if (!walker.currentNode.textContent.trim()) continue;
        range.selectNodeContents(walker.currentNode);
        for (const box of range.getClientRects()) if (box.height > 0) spans.push([box.top + scrollY, box.bottom + scrollY]);
      }
      for (const el of document.querySelectorAll('img, pre, figure, tr')) {
        const box = el.getBoundingClientRect();
        if (box.height > 0) spans.push([box.top + scrollY, box.bottom + scrollY]);
      }
      return { height: document.documentElement.scrollHeight, spans };
    })()
    """

    private func finish(_ ok: Bool) {
        let then = self.then
        self.then = nil
        then?(ok)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(false) }
    }
}
