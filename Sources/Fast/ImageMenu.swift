import AppKit
import UniformTypeIdentifiers
import WebKit

// Right-click on a picture: WebKit's own menu, with the link's rows when the
// picture is a link, Inspect Element and what extensions add, and three of
// its rows done by Yab rather than by WebKit (PageView.imagesHere).
//
// WebKit's Download Image never asks for a download at all (it isn't a
// navigation, so nothing this app's own WKNavigationDelegate sees applies to
// it), and its Copy Image writes the kind of pasteboard promise a paste, as
// opposed to a drag, doesn't always resolve: the empty box some apps show for
// what should have been a picture. There is no public hook to fix those rows
// from the outside, so the rows stay and what they do is Yab's: the picture
// fetched with the page's own cookies and written as real bytes, the
// download started the way the app's other downloads are. Open Image goes to
// a tab, and Copy Image Address, which WebKit's menu lacks, is added.
//
// Which picture: the page's contextmenu event names it, heard here a moment
// before the menu opens, and nothing on the page is kept from it. Where none
// was heard, a picture from a file:, WebKit's own row does it.

/// A row of the picture's menu, done by Yab.
enum ImageAct: String { case open, copy, download, address, ask, capture }

final class ImageRelay: NSObject, PageScriptReceiving {
    static let name = "yabImages"

    weak var tab: Tab?

    /// A link element's address, or "" for anything else. An SVG link's
    /// href is an SVGAnimatedString, not a string, and isn't resolved
    /// against the page.
    static let linkOf = """
    function (a) {
      if (!a || (a.tagName !== 'A' && a.tagName !== 'a')) return '';
      var href = a.href;
      if (href && typeof href.baseVal === 'string') {
        if (!href.baseVal) return '';
        try { return new URL(href.baseVal, a.baseURI).href; } catch (err) { return ''; }
      }
      return typeof href === 'string' ? href : '';
    }
    """

    /// Every frame: an image inside an ad or a map embed is still an image.
    /// Only the ways a picture arrives, http, data and blob: file: and the
    /// rest are WebKit's to copy.
    static let watch = """
    (function () {
      if (window.__yabImages) return;
      window.__yabImages = true;
      // The playlists this frame fetched, and the last piece of media it
      // fetched by script, for Download Video on a video that plays from a
      // blob: (VideoSave.swift). Read from the resource timing, not by
      // wrapping the page's fetch.
      var playlists = [], segment = '';
      try {
        new PerformanceObserver(function (list) {
          list.getEntries().forEach(function (p) {
            var n = p.name || '';
            if (/\\.(m3u8|mpd)(\\?|#|$)/i.test(n)) {
              playlists.push(n);
              if (playlists.length > 40) playlists.shift();
            } else if ((p.initiatorType === 'fetch' || p.initiatorType === 'xmlhttprequest')
                       && /\\.(m4s|mp4|m4v|m4a|aac|ts)(\\?|#|$)/i.test(n)) {
              segment = n;
            }
          });
        }).observe({ type: 'resource', buffered: true });
      } catch (err) {}
      document.addEventListener('contextmenu', function (e) {
        // A video or a sound under it, for Download Video: the element
        // itself, or one under the controls a site lays over it (x.com).
        var media = null, chain = e.composedPath ? e.composedPath() : [];
        for (var m = 0; m < chain.length && !media; m++) {
          if (chain[m] && (chain[m].tagName === 'VIDEO' || chain[m].tagName === 'AUDIO')) media = chain[m];
        }
        if (!media && document.elementsFromPoint) {
          var stack = document.elementsFromPoint(e.clientX, e.clientY);
          for (var k = 0; k < stack.length && !media; k++) {
            if (stack[k].tagName === 'VIDEO' || stack[k].tagName === 'AUDIO') media = stack[k];
          }
        }
        if (media && e.isTrusted) {
          var sources = [];
          media.querySelectorAll('source').forEach(function (s) { if (s.src) sources.push(s.src); });
          window.webkit.messageHandlers.yabImages.postMessage({ media: {
            src: media.currentSrc || media.src || '', sources: sources, poster: media.poster || '',
            playlists: playlists.slice(), segment: segment, audio: media.tagName === 'AUDIO' } });
        }
        // A mailto: link under it, for the menu's Copy Email Address
        // (PageView.emailHere): the nearest link, in a shadow root too.
        var path = e.composedPath ? e.composedPath() : [];
        var contextLink = '', linkOf = \(linkOf);
        for (var i = 0; i < path.length; i++) {
          var href = linkOf(path[i]);
          if (!href) continue;
          if (/^https?:/i.test(href)) contextLink = href;
          if (/^mailto:/i.test(href)) window.webkit.messageHandlers.yabImages.postMessage({ link: href });
          break;
        }
        // Empty too: a later menu on plain text must not reuse an old link.
        if (e.isTrusted) window.webkit.messageHandlers.yabImages.postMessage({ contextLink: contextLink, contextAt: Date.now() });
        var el = path.find(function (node) { return node && node.tagName === 'IMG'; }) || e.target;
        while (el && el.tagName !== 'IMG') el = el.parentElement;
        if (!el || !el.currentSrc || !/^(https?|data|blob):/i.test(el.currentSrc)) {
          window.webkit.messageHandlers.yabImages.postMessage({ src: '' });
          return;
        }
        var box = el.getBoundingClientRect();
        window.webkit.messageHandlers.yabImages.postMessage({ src: el.currentSrc,
          referrerPolicy: el.referrerPolicy || document.referrerPolicy || '',
          box: [box.left, box.top, box.width, box.height] });
      }, true);
      // The pointer resting on a picture big enough to hold words, in the
      // page's own frame: what shows of it is read (PictureReader.look).
      // Only a picture the pointer went to, not one a scroll carried under
      // a pointer at rest: WebKit tells the page the pointer is over each
      // picture going by, and on a feed every pause of a scroll read the
      // thumbnail under it and asked WebKit to read the whole page's
      // pictures, and every one it loads after that (row 1051,
      // evals/scroll-ram).
      if (window !== window.top) return;
      var timer = 0, under = null, scrolled = -Infinity;
      addEventListener('scroll', function () {
        scrolled = performance.now();
        if (under) { under = null; clearTimeout(timer); }
      }, { capture: true, passive: true });
      function reached(el) {
        if (!el || el.tagName !== 'IMG' || el === under) return;
        // WebKit's own pointer moves after a scroll come within a quarter
        // of a second of its last frame.
        if (performance.now() - scrolled < 600) return;
        clearTimeout(timer);
        under = el;
        timer = setTimeout(function () {
          if (!el.isConnected || under !== el || !/^(https?|data|blob):/i.test(el.currentSrc || '')) return;
          var r = el.getBoundingClientRect();
          var left = Math.max(r.left, 0), top = Math.max(r.top, 0);
          var right = Math.min(r.right, innerWidth), bottom = Math.min(r.bottom, innerHeight);
          if (right - left < 40 || bottom - top < 16) return;
          var whole = left === r.left && top === r.top && right === r.right && bottom === r.bottom;
          window.webkit.messageHandlers.yabImages.postMessage({ look: el.currentSrc, rect: [left, top, right - left, bottom - top], whole: whole });
        }, 350);
      }
      document.addEventListener('pointerover', function (e) { reached(e.target); }, true);
      // A picture a scroll left under the pointer counts once the pointer
      // itself moves on it.
      document.addEventListener('pointermove', function (e) { if (e.movementX || e.movementY) reached(e.target); }, true);
      document.addEventListener('pointerout', function (e) {
        if (e.target === under) { under = null; clearTimeout(timer); }
      }, true);
    })();
    """

    func receive(_ message: PageScriptMessage) {
        if let body = message.body as? [String: Any], let link = body["contextLink"] as? String,
           let at = body["contextAt"] as? Double, at.isFinite {
            MainActor.assumeIsolated { [weak self] in
                self?.tab?.webKitOnly("WebKit image context", build: false)?.heardContextLink(link, at: at)
            }
            return
        }
        if let body = message.body as? [String: Any], let src = body["look"] as? String,
           let rect = body["rect"] as? [Double], rect.count == 4, message.frame.isMain {
            if LinkGap.cut("pictures") { return }
            MainActor.assumeIsolated { [weak self] in
                guard let tab = self?.tab, let web = tab.webKitOnly("WebKit image context", build: false) else { return }
                tab.lookAtPictures()
                PictureReader.shared.look(src, at: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]),
                                          whole: body["whole"] as? Bool == true, in: web)
            }
            return
        }
        if let body = message.body as? [String: Any], let found = body["media"] as? [String: Any],
           let media = PointedMedia(found) {
            MainActor.assumeIsolated { [weak self] in
                self?.tab?.pointedMedia = (media, CACurrentMediaTime())
            }
            return
        }
        if let body = message.body as? [String: Any], let link = body["link"] as? String,
           let url = URL(string: link), url.scheme?.lowercased() == "mailto" {
            MainActor.assumeIsolated { [weak self] in
                self?.tab?.pointedLink = (url, CACurrentMediaTime())
            }
            return
        }
        guard let body = message.body as? [String: Any], let src = body["src"] as? String else { return }
        if src.isEmpty {
            MainActor.assumeIsolated { self.tab?.pointedImage = nil; self.tab?.pointedImageFrame = nil; self.tab?.pointedImageBox = nil }
            return
        }
        guard
              let url = URL(string: src),
              ["http", "https", "data", "blob"].contains(url.scheme?.lowercased() ?? "")
        else { return }
        MainActor.assumeIsolated { [weak self] in
            self?.tab?.pointedImage = (url, CACurrentMediaTime())
            self?.tab?.pointedImageFrame = message.frame.token as? WKFrameInfo
            self?.tab?.pointedImagePolicy = body["referrerPolicy"] as? String ?? ""
            // A frame's own coordinates say nothing about the page's.
            let box = message.frame.isMain ? (body["box"] as? [Double]).flatMap { $0.count == 4 ? $0 : nil } : nil
            self?.tab?.pointedImageBox = box.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        }
    }
}

extension Browser {
    /// A row of the picture's menu, picked.
    func imageAct(_ act: ImageAct, _ url: URL, in tab: Tab, foreground: Bool = true) {
        switch act {
        case .open:
            openBeside(url, from: tab, foreground: foreground)
        case .copy:
            copyImage(at: url, from: tab)
        case .capture:
            capture.image(url, on: tab)
        case .download:
            if let page = tab.builtPage as? ChromiumPage { page.startDownload(url); return }
            guard let web = tab.webKitOnly("WebKit image context", build: false) else { return }
            if ["data", "blob"].contains(url.scheme?.lowercased() ?? "") {
                let frame = tab.pointedImage?.url == url ? tab.pointedImageFrame : nil
                let download = ImageDownload(url: url, page: web, frame: frame)
                keep(download)
                pictureDownloads.insert(download.downloadID)
                download.start()
                return
            }
            let source = tab.pointedImage?.url == url ? tab.pointedImageFrame?.request.url : tab.address
            let request = DownloadRequest.resource(url, from: source ?? tab.address,
                                               policy: tab.pointedImage?.url == url ? tab.pointedImagePolicy : "")
            web.startDownload(using: request) { [weak self] download in
                self?.keep(download)
                self?.pictureDownloads.insert(download.downloadID)
            }
        case .address:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            toaster.pop("Image address copied", mark: "link")
        case .ask:
            askAbout(url, on: tab)
        }
    }

    /// Ask About Image: ⌘J about the page, the picture given with it as a
    /// file on this Mac, as a screenshot added to the ask is, which the
    /// agent opens and looks at; in a chat when Settings › AI › Agents says
    /// so. Never from a private tab, whose page no agent is given.
    func askAbout(_ url: URL, on tab: Tab) {
        guard !tab.shy else { return }
        Task {
            guard let data = await Self.imageData(url, from: tab) else {
                announce("Couldn’t get the picture", mark: "exclamationmark.triangle")
                return
            }
            // A folder of its own, so the chip says the picture's name alone.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-pictures/" + UUID().uuidString)
            let file = folder.appendingPathComponent(Self.pictureName(url, data, on: tab))
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
                  (try? data.write(to: file)) != nil else { return }
            if prefs.askOpens == .chat {
                askInChat(about: tab, context: [.page(tab), .file(file)])
                return
            }
            let line = TaskLine.shared
            // Already up on this page: the picture joins what it holds.
            if line.tab != tab.id { line.open(on: tab) }
            line.add(files: [file])
            line.focusRequest += 1
        }
    }

    /// The picture's file: its own name where it has one, "yab-<site>-
    /// picture" where it doesn't, and the kind its bytes say it is.
    static func pictureName(_ url: URL, _ data: Data, on tab: Tab) -> String {
        let kind = CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType)
            .flatMap { UTType($0 as String)?.preferredFilenameExtension } ?? "png"
        let own = url.scheme?.hasPrefix("http") == true ? url.deletingPathExtension().lastPathComponent : ""
        let base = own.isEmpty || own == "/" || own.count > 60
            ? "yab-" + ChatComposer.host(tab) + "-picture"
            : own.replacingOccurrences(of: #"[^\w.\-]+"#, with: "-", options: .regularExpression)
        return base + "." + kind
    }

    /// Fetched once, as the page has it, and written as an actual image
    /// rather than a reference to one: an NSImage hands a receiving app real
    /// bytes to choose from, TIFF, PNG, whatever it asks for, which is the
    /// thing a pasteboard promise doesn't always give back on a paste.
    func copyImage(at url: URL, from tab: Tab) {
        let request = ImageCopy.shared.begin(on: .general)
        Task {
            _ = await ImageCopy.shared.copy(request, read: { await Self.imageData(url, from: tab) }) { wrote in
                if wrote {
                    announce("Image copied", mark: "photo", feedback: .success)
                } else {
                    announce("Couldn’t copy the image", mark: "exclamationmark.triangle")
                }
            }
        }
    }

    /// The picture's bytes: a blob: read by its own page, the only place it
    /// lives; anything else fetched with the page's cookies and its address
    /// as the referrer, so a picture behind a sign-in comes too.
    /// `largest`: only to be read, no longer than that many pixels on a
    /// side (Chromium scales it down in the page's renderer).
    static func imageData(_ url: URL, from tab: Tab, largest: Int? = nil) async -> Data? {
        if let page = tab.builtPage as? ChromiumPage { return await page.imageData(url, largest: largest) }
        guard let web = tab.webKitOnly("WebKit image context", build: false) else { return nil }
        if url.scheme?.lowercased() == "data" { return try? ImageDownload.inline(url).data }
        if url.scheme?.lowercased() == "blob" {
            let read = """
            const r = await fetch(src);
            if (!r.ok) return null;
            const bytes = new Uint8Array(await r.arrayBuffer());
            let s = '';
            for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
            return btoa(s);
            """
            let frame = tab.pointedImage?.url == url ? tab.pointedImageFrame : nil
            let found = try? await web.callAsyncJavaScript(read, arguments: ["src": url.absoluteString], in: frame, contentWorld: .defaultClient)
            return (found as? String).flatMap { Data(base64Encoded: $0) }
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        if url.scheme?.hasPrefix("http") == true {
            let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies.filter { AgentRead.sent($0, to: url) }) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            request.setValue(AgentRead.userAgent, forHTTPHeaderField: "User-Agent")
            if let page = tab.address?.absoluteString { request.setValue(page, forHTTPHeaderField: "Referer") }
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              !(response is HTTPURLResponse) || (200..<300).contains((response as! HTTPURLResponse).statusCode) else { return nil }
        return data
    }
}
