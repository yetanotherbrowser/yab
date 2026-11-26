import AppKit
import YabDesign
import YabCoreClient

private extension JSONValue {
    var menuList: [JSONValue] { if case .array(let rows) = self { return rows }; return [] }
}

/// What Chromium said about a right-click, from its browser-process params
/// (CefContextMenuParams), never from a page-authored message.
struct ChromiumMenuContext {
    struct ExtensionRow: Equatable {
        let command: Int
        let label: String
        let enabled: Bool
        let checked: Bool
        let rows: [ExtensionRow]
    }

    let request: String
    /// Top-left page point of the press, in the page's points.
    let point: CGPoint
    let link: URL?
    let copyLink: String
    let source: URL?
    let media: Int
    let hasImage: Bool
    let selection: String
    let editable: Bool
    let editFlags: Int
    let misspelled: String
    let suggestions: [String]
    /// Chrome's spelling commands this menu offers, and whether each is on.
    let spelling: [Int: Bool]
    /// Chrome's own edit commands this menu offers (chrome_command_ids.h).
    let chrome: Set<Int>
    /// A video's or a sound's own rows Chrome's menu has (Loop, Show all
    /// controls, Picture in picture), whether each can run and is on.
    let mediaRows: [Int: (enabled: Bool, checked: Bool)]
    let extensions: [ExtensionRow]
    /// The press was in Chrome's DevTools: only their own rows.
    let devToolsFrontend: Bool

    static let copy = 50150, cut = 50151, paste = 50152, selectAll = 50156
    /// Chrome's Save Image As, offered by YabCore when Chrome's menu has it.
    static let saveImageAs = 50120
    static let spellingWhileTyping = 41107, addToDictionary = 41110
    static let mediaImage = 1, mediaVideo = 2, mediaAudio = 3
    /// IDC_CONTENT_CONTEXT_PICTUREINPICTURE, _LOOP and _CONTROLS.
    static let pictureInPicture = 50137, loop = 50140, controls = 50141
    /// IDC_CONTENT_CONTEXT_SAVEVIDEOFRAMEAS and _COPYVIDEOFRAME.
    static let saveVideoFrameAs = 50130, copyVideoFrame = 50133

    init?(_ p: [String: JSONValue]) {
        guard let request = p["request"]?.string, !request.isEmpty else { return nil }
        self.request = request
        point = CGPoint(x: p["x"]?.number ?? 0, y: p["y"]?.number ?? 0)
        let web = { (value: String?) -> URL? in
            guard let value, !value.isEmpty, let url = URL(string: value),
                  !["javascript", "chrome", "chrome-extension", "devtools"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }
        link = web(p["link"]?.string)
        copyLink = p["unfilteredLink"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? link?.absoluteString ?? ""
        source = web(p["source"]?.string)
        media = Int(p["media"]?.number ?? 0)
        hasImage = p["hasImage"] == .bool(true)
        selection = p["selection"]?.string ?? ""
        editable = p["editable"] == .bool(true)
        editFlags = Int(p["editFlags"]?.number ?? 0)
        misspelled = p["misspelled"]?.string ?? ""
        suggestions = (p["suggestions"]?.menuList ?? []).compactMap(\.string)
        spelling = Dictionary((p["spelling"]?.menuList ?? []).compactMap { row in
            row["command"].number.map { (Int($0), row["checked"] == .bool(true)) }
        }, uniquingKeysWith: { first, _ in first })
        chrome = Set((p["chrome"]?.menuList ?? []).compactMap { $0.number.map(Int.init) })
        mediaRows = Dictionary((p["mediaRows"]?.menuList ?? []).compactMap { row in
            row["command"].number.map { (Int($0), (enabled: row["enabled"] == .bool(true), checked: row["checked"] == .bool(true))) }
        }, uniquingKeysWith: { first, _ in first })
        func rows(_ value: JSONValue?, depth: Int) -> [ExtensionRow] {
            guard depth < 4 else { return [] }
            return (value?.menuList ?? []).compactMap { row in
                guard let command = row["command"].number, let label = row["label"].string else { return nil }
                return ExtensionRow(command: Int(command), label: label, enabled: row["enabled"] == .bool(true),
                                    checked: row["checked"] == .bool(true), rows: rows(row["rows"], depth: depth + 1))
            }
        }
        extensions = rows(p["extensions"], depth: 0)
        devToolsFrontend = p["devToolsFrontend"] == .bool(true)
    }
}

/// A row of Yab's page menu on a Chromium tab: WebKit's row identifiers, so
/// PageView.dress and every test that reads them see the same menu.
struct ChromiumMenuRow: Equatable {
    enum Action: Equatable {
        case chrome(Int)
        case openTab(URL), openSplit(URL), openPrivate(URL), openHere(URL), download(URL), copy(String)
        case image(ImageAct, URL)
        case search(String), goTo(URL), lookUp(String), replace(String)
        case back, forward, reload
        case inspect
        case selectionCommand(String?), hide, capture, saveMedia(URL), share(URL)
    }
    let title: String
    let id: String?
    let action: Action?
    var enabled = true
    var checked = false
    var rows: [ChromiumMenuRow?] = []
    /// The system symbol WebKit's own row wears for the same thing, where
    /// Yab's marks (PageView.marks) have none: PageView.dress leaves it.
    var symbol: String? = nil

    /// The rows, nil for a separator, in WebKit's order for the same press.
    /// `web`: a page of a site, where Capture and Hide Element mean something.
    @MainActor static func rows(for c: ChromiumMenuContext, searchName: String, canGoBack: Bool, canGoForward: Bool,
                     askable: Bool, commands: [SelectionCommand] = [], website: Bool = false,
                     privateLink: Bool = true) -> [ChromiumMenuRow?] {
        var out: [ChromiumMenuRow?] = []
        let section = { (rows: [ChromiumMenuRow]) in
            guard !rows.isEmpty else { return }
            if !out.isEmpty { out.append(nil) }
            out += rows
        }
        if c.editable, !c.misspelled.isEmpty {
            var rows = c.suggestions.isEmpty
                ? [ChromiumMenuRow(title: "No Guesses Found", id: nil, action: nil, enabled: false)]
                : c.suggestions.prefix(5).map { ChromiumMenuRow(title: $0, id: nil, action: .replace($0)) }
            if c.spelling[ChromiumMenuContext.addToDictionary] != nil {
                rows.append(ChromiumMenuRow(title: "Add to Dictionary", id: nil, action: .chrome(ChromiumMenuContext.addToDictionary)))
            }
            section(rows)
        }
        if let link = c.link {
            var rows: [ChromiumMenuRow] = []
            let scheme = link.scheme?.lowercased() ?? ""
            if scheme != "mailto" && scheme != "tel" {
                rows.append(ChromiumMenuRow(title: "Open Link in New Tab", id: "WKMenuItemIdentifierOpenLinkInNewWindow", action: .openTab(link)))
                // What ⌥-click on the link does (Browser.splitLink), as Arc's menu had it (feedback #1900).
                if ["http", "https"].contains(scheme) {
                    rows.append(ChromiumMenuRow(title: PageView.splitLinkTitle, id: PageView.splitLinkID, action: .openSplit(link)))
                    if privateLink {
                        rows.append(ChromiumMenuRow(title: PageView.privateLinkTitle, id: PageView.privateLinkID, action: .openPrivate(link)))
                    }
                }
                rows.append(ChromiumMenuRow(title: "Open Link", id: "WKMenuItemIdentifierOpenLink", action: .openHere(link)))
                if ["http", "https", "data", "blob"].contains(scheme) {
                    rows.append(ChromiumMenuRow(title: "Download Linked File", id: "WKMenuItemIdentifierDownloadLinkedFile", action: .download(link)))
                }
            }
            rows.append(ChromiumMenuRow(title: "Copy Link", id: "WKMenuItemIdentifierCopyLink", action: .copy(c.copyLink)))
            if ["http", "https"].contains(scheme) {
                rows.append(ChromiumMenuRow(title: "Share\u{2026}", id: "WKMenuItemIdentifierShareMenu", action: .share(link)))
            }
            if let address = PageView.emailAddress(link) {
                rows.append(ChromiumMenuRow(title: "Copy Email Address", id: "YabCopyEmailAddress", action: .copy(address)))
            }
            if let words = Self.words(c.selection), let url = SelectedURLMenu.url(words, besides: link.absoluteString) {
                rows.append(ChromiumMenuRow(title: "Go to “\(Address.pretty(url))”", id: "YabGoToSelectedURL", action: .goTo(url)))
            }
            section(rows)
        }
        if c.media == ChromiumMenuContext.mediaImage, let image = c.source {
            // Chrome's own Save Image As fetches the picture as the frame
            // showing it does: its page as referrer, the image Accept header,
            // the cached copy. A fresh download of the address had none of it,
            // and a site that checks the referrer refused it (row 1611).
            let download: Action = c.chrome.contains(ChromiumMenuContext.saveImageAs)
                ? .chrome(ChromiumMenuContext.saveImageAs) : .image(.download, image)
            var rows = [ChromiumMenuRow(title: "Open Image in New Tab", id: "WKMenuItemIdentifierOpenImageInNewWindow", action: .image(.open, image)),
                        ChromiumMenuRow(title: "Download Image", id: "WKMenuItemIdentifierDownloadImage", action: download)]
            if c.hasImage {
                rows.append(ChromiumMenuRow(title: "Copy Image", id: "WKMenuItemIdentifierCopyImage", action: .image(.copy, image)))
                rows.append(ChromiumMenuRow(title: "Capture Image", id: "YabCaptureImage", action: .image(.capture, image)))
            }
            rows.append(ChromiumMenuRow(title: "Copy Image Address", id: "YabCopyImageAddress", action: .image(.address, image)))
            if askable, c.hasImage {
                rows.append(ChromiumMenuRow(title: "Ask About Image", id: "YabAskAboutImage", action: .image(.ask, image)))
            }
            section(rows)
        } else if c.media == ChromiumMenuContext.mediaVideo || c.media == ChromiumMenuContext.mediaAudio {
            section(Self.playerRows(c))
        }
        if c.media == ChromiumMenuContext.mediaVideo || c.media == ChromiumMenuContext.mediaAudio, let media = c.source {
            let kind = c.media == ChromiumMenuContext.mediaAudio ? "Audio" : "Video"
            var rows = [ChromiumMenuRow(title: "Open \(kind) in New Tab", id: "WKMenuItemIdentifierOpenMediaInNewWindow", action: .openTab(media))]
            // Chrome's frame rows, in Chrome's words and places around the
            // video's own (AppendVideoItems): rows Yab's WebKit menu never had.
            let frame = { (command: Int, title: String) -> ChromiumMenuRow? in
                c.mediaRows[command].map { ChromiumMenuRow(title: title, id: nil, action: .chrome(command), enabled: $0.enabled) }
            }
            if let save = frame(ChromiumMenuContext.saveVideoFrameAs, "Save Video Frame As\u{2026}") { rows.append(save) }
            // A blob's or a stream's video too: VideoSave reads what the page played.
            if ["http", "https", "blob"].contains(media.scheme?.lowercased() ?? "") {
                rows.append(ChromiumMenuRow(title: VideoSave.downloadTitle(PointedMedia(src: media.absoluteString, audio: c.media == ChromiumMenuContext.mediaAudio)), id: "YabDownloadMedia", action: .saveMedia(media)))
            }
            if let copy = frame(ChromiumMenuContext.copyVideoFrame, "Copy Video Frame") { rows.append(copy) }
            rows.append(ChromiumMenuRow(title: "Copy \(kind) Address", id: "WKMenuItemIdentifierCopyMediaLink", action: .copy(media.absoluteString)))
            section(rows)
        }
        if let words = Self.words(c.selection), c.link == nil {
            var rows = [ChromiumMenuRow(title: "Look Up “\(Self.short(words))”", id: "WKMenuItemIdentifierLookUp", action: .lookUp(words))]
            if let url = SelectedURLMenu.url(words) {
                rows.append(ChromiumMenuRow(title: "Go to “\(Address.pretty(url))”", id: "YabGoToSelectedURL", action: .goTo(url)))
            }
            rows.append(ChromiumMenuRow(title: "Search with \(searchName)", id: "WKMenuItemIdentifierSearchWeb", action: .search(words)))
            section(rows)
            section(commands.map { ChromiumMenuRow(title: SelectionCommand.menuTitle($0.name), id: nil, action: .selectionCommand($0.id)) }
                + [ChromiumMenuRow(title: "More Commands\u{2026}", id: "YabMoreCommands", action: .selectionCommand(nil))])
        }
        if c.editable {
            var rows: [ChromiumMenuRow] = []
            for (title, command, id) in [("Cut", ChromiumMenuContext.cut, nil), ("Copy", ChromiumMenuContext.copy, "WKMenuItemIdentifierCopy"),
                                         ("Paste", ChromiumMenuContext.paste, "WKMenuItemIdentifierPaste"),
                                         ("Select All", ChromiumMenuContext.selectAll, nil)] as [(String, Int, String?)] {
                rows.append(ChromiumMenuRow(title: title, id: id, action: .chrome(command), enabled: c.chrome.contains(command)))
            }
            section(rows)
            if let on = c.spelling[ChromiumMenuContext.spellingWhileTyping] {
                section([ChromiumMenuRow(title: "Spelling and Grammar", id: nil, action: nil, rows: [
                    ChromiumMenuRow(title: "Check Spelling While Typing", id: nil, action: .chrome(ChromiumMenuContext.spellingWhileTyping), checked: on)])])
            }
        } else if Self.words(c.selection) != nil, c.link == nil, c.chrome.contains(ChromiumMenuContext.copy) {
            section([ChromiumMenuRow(title: "Copy", id: "WKMenuItemIdentifierCopy", action: .chrome(ChromiumMenuContext.copy))])
        }
        if c.link == nil, c.source == nil || c.media == 0, Self.words(c.selection) == nil, !c.editable {
            var rows = [ChromiumMenuRow(title: "Back", id: "WKMenuItemIdentifierGoBack", action: .back, enabled: canGoBack),
                        ChromiumMenuRow(title: "Forward", id: "WKMenuItemIdentifierGoForward", action: .forward, enabled: canGoForward),
                        ChromiumMenuRow(title: "Reload", id: "WKMenuItemIdentifierReload", action: .reload)]
            section(rows)
        }
        func extensionRows(_ rows: [ChromiumMenuContext.ExtensionRow]) -> [ChromiumMenuRow?] {
            rows.map { row in
                ChromiumMenuRow(title: row.label, id: nil, action: row.rows.isEmpty ? .chrome(row.command) : nil,
                                enabled: row.enabled, checked: row.checked, rows: extensionRows(row.rows))
            }
        }
        section(extensionRows(c.extensions).compactMap { $0 })
        var tools: [ChromiumMenuRow] = []
        if website, !c.devToolsFrontend {
            if out.contains(where: { $0?.id == "WKMenuItemIdentifierReload" }) {
                tools.append(ChromiumMenuRow(title: "Capture\u{2026}", id: "YabCapturePage", action: .capture))
            }
            tools.append(ChromiumMenuRow(title: "Hide Element", id: "YabHideElement", action: .hide))
        }
        if !c.devToolsFrontend {
            tools.append(ChromiumMenuRow(title: "Inspect Element", id: "WKMenuItemIdentifierInspectElement", action: .inspect))
        }
        section(tools)
        return out
    }

    /// A video's or a sound's own rows, as WebKit's menu had them for the
    /// same press (its words, order and pictures), each Chrome's own row run
    /// by Chrome on the element pressed: Show all controls, Loop and Picture
    /// in picture (RenderViewContextMenu::AppendMediaItems, AppendVideoItems).
    /// Only the rows Chromium's menu has, enabled and checked as Chromium's are.
    static func playerRows(_ c: ChromiumMenuContext) -> [ChromiumMenuRow] {
        var rows: [ChromiumMenuRow] = []
        if let controls = c.mediaRows[ChromiumMenuContext.controls] {
            rows.append(ChromiumMenuRow(title: controls.checked ? "Hide Controls" : "Show Controls", id: "WKMenuItemIdentifierShowHideMediaControls",
                                        action: .chrome(ChromiumMenuContext.controls), enabled: controls.enabled,
                                        symbol: controls.checked ? "eye.slash" : "eye"))
        }
        if let loop = c.mediaRows[ChromiumMenuContext.loop] {
            rows.append(ChromiumMenuRow(title: "Loop", id: nil, action: .chrome(ChromiumMenuContext.loop), enabled: loop.enabled,
                                        checked: loop.checked, symbol: "arrow.2.squarepath"))
        }
        if c.media == ChromiumMenuContext.mediaVideo, let pip = c.mediaRows[ChromiumMenuContext.pictureInPicture] {
            rows.append(ChromiumMenuRow(title: pip.checked ? "Exit Picture in Picture" : "Enter Picture in Picture",
                                        id: "WKMenuItemIdentifierToggleEnhancedFullScreen",
                                        action: .chrome(ChromiumMenuContext.pictureInPicture), enabled: pip.enabled,
                                        symbol: pip.checked ? "pip.exit" : "pip.enter"))
        }
        return rows
    }

    static func words(_ selection: String) -> String? {
        let words = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// Look Up's title holds the words as WebKit's does, cut short.
    static func short(_ words: String) -> String {
        let flat = words.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 30 ? String(flat.prefix(29)) + "\u{2026}" : flat
    }
}

/// One right-click's menu on screen. Chrome's continuation stays open until
/// the row chosen is known, or a moment after the menu closed with none:
/// a row can be performed just after tracking ends (bench "press").
@MainActor
final class ChromiumMenuSession: NSObject {
    let context: ChromiumMenuContext
    weak var page: ChromiumPage?
    let remote: String?
    private var answered = false

    init(context: ChromiumMenuContext, page: ChromiumPage) {
        self.context = context
        self.page = page
        remote = page.remoteID
    }

    func answer(_ command: Int?) {
        guard !answered, let page, page.remoteID == remote else { return }
        answered = true
        var params: [String: JSONValue] = ["request": .string(context.request)]
        if let command { params["command"] = .number(Double(command)) }
        Task { @MainActor in _ = try? await page.navigationRequest("menu.reply", params) }
    }

    /// Held here, not by the rows (a menu item's target is weak), until then.
    func closed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.answer(nil) }
    }

    @objc func pick(_ item: NSMenuItem) {
        guard let box = item.representedObject as? Box, let page else { answer(nil); return }
        if case .chrome(let command) = box.action {
            // The file Chrome starts for it is this press's, as Download
            // Linked File's is (ChromiumDownload.wasAsked).
            if command == ChromiumMenuContext.saveImageAs, let image = context.source { ChromiumDownload.ask(image, on: page) }
            // The frame's file has an address of its own, a blob's, known only once it starts.
            if command == ChromiumMenuContext.saveVideoFrameAs { ChromiumDownload.askFrame(on: page) }
            answer(command)
            return
        }
        answer(nil)
        page.performMenu(box.action, at: context.point, audio: context.media == ChromiumMenuContext.mediaAudio)
    }

    final class Box: NSObject {
        let action: ChromiumMenuRow.Action
        init(_ action: ChromiumMenuRow.Action) { self.action = action }
    }
}

extension ChromiumPage {
    func receiveMenu(_ p: [String: JSONValue]) {
        guard let context = ChromiumMenuContext(p) else { return }
        let session = ChromiumMenuSession(context: context, page: self)
        guard window != nil, let tab = navigationTab else { session.answer(nil); return }
        let rows = ChromiumMenuRow.rows(for: context, searchName: tab.onSearchName?(tab) ?? Engine.name,
                                        canGoBack: canGoBack, canGoForward: canGoForward, askable: !tab.shy,
                                        commands: tab.onSelectionMenu?(tab) ?? [],
                                        website: ["http", "https"].contains(url?.scheme?.lowercased() ?? ""),
                                        privateLink: !tab.shy)
        guard !rows.isEmpty else { session.answer(nil); return }
        let menu = Self.pageMenu(rows, session: session)
        let translation = tab.onTranslationMenu?(tab) ?? []
        if !translation.isEmpty {
            menu.addItem(.separator())
            translation.forEach(menu.addItem)
        }
        PageView.dress(menu)
        for item in menu.items where item.identifier == nil && item.action == #selector(ChromiumMenuSession.pick(_:)) {
            if let box = item.representedObject as? ChromiumMenuSession.Box, case .chrome(let command) = box.action,
               (49000..<50000).contains(command), !isDevToolsFrontend {
                item.image = MenuMark.image("puzzlepiece.extension")
                MenuMark.show(item)
            }
        }
        PageView.menuWatch?(menu)
        let at = NSPoint(x: context.point.x, y: bounds.height - context.point.y)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { session.answer(nil); return }
            // popUp tracks in its own loop and returns once the menu closed.
            // AppKit attaches its AutoFill submenu to a contextual menu
            // for the actual text input client. A plain positioned popup
            // bypasses that path, so Chromium lost the system password,
            // contact and card actions which WebKit's context menu gets.
            // Keep DevTools' own menus out of the page's text services.
            if context.editable, !context.devToolsFrontend,
               let event = NSEvent.mouseEvent(with: .rightMouseDown,
                   location: self.convert(at, to: nil), modifierFlags: NSEvent.modifierFlags,
                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.makeFirstResponder(self)
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            } else {
                menu.popUp(positioning: nil, at: at, in: self)
            }
            session.closed()
            self.lastInput = ProcessInfo.processInfo.systemUptime
        }
    }

    private static func pageMenu(_ rows: [ChromiumMenuRow?], session: ChromiumMenuSession) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for row in rows {
            guard let row else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
            if let id = row.id { item.identifier = NSUserInterfaceItemIdentifier(id) }
            item.isEnabled = row.enabled
            item.state = row.checked ? .on : .off
            if let symbol = row.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                item.image = image
                MenuMark.show(item)
            }
            if !row.rows.isEmpty {
                item.submenu = pageMenu(row.rows, session: session)
            } else if let action = row.action {
                item.target = session
                item.action = #selector(ChromiumMenuSession.pick(_:))
                item.representedObject = ChromiumMenuSession.Box(action)
            }
            let shortcut = row.id == "YabAskAboutImage" || row.id == "YabMoreCommands" ? Keymap.shared.keys(.agentAsk)
                : row.id == "YabCapturePage" ? Keymap.shared.keys(.capture) : nil
            if let key = shortcut, key.key.count == 1 {
                item.keyEquivalent = key.key
                item.keyEquivalentModifierMask = key.flags
            }
            menu.addItem(item)
        }
        return menu
    }

    func performMenu(_ action: ChromiumMenuRow.Action, at point: CGPoint, audio: Bool = false) {
        guard let tab = navigationTab else { return }
        let browser = tab.delegate as? Browser
        switch action {
        case .chrome: break
        case .inspect:
            browser?.inspectChromium(tab, at: point)
        case .share(let url):
            NSSharingServicePicker(items: [url]).show(relativeTo: NSRect(x: point.x, y: bounds.height - point.y, width: 1, height: 1), of: self, preferredEdge: .minY)
        case .openTab(let url):
            // Shift asks to show it, as WebKit's Open Link in New Tab does.
            let foreground = NSEvent.modifierFlags.contains(.shift)
            guard let browser else { return }
            if !browser.routePageLink(url, from: tab, foreground: foreground) {
                browser.open(url, foreground: foreground, from: tab, linked: true)
            }
        case .openSplit(let url): browser?.splitLink(url, from: tab)
        case .openPrivate(let url): browser?.newPrivateWindow(opening: url)
        case .openHere(let url): tab.go(to: url)
        case .download(let url): startDownload(url)
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .image(let act, let url):
            let flags = NSEvent.modifierFlags
            tab.onImageAct?(tab, act, url, !flags.contains(.command) || flags.contains(.shift))
        case .search(let words): tab.onSearch?(tab, words)
        case .goTo(let url): tab.onSelectedURL?(tab, url, NSEvent.modifierFlags)
        case .lookUp(let words):
            let text = NSAttributedString(string: words, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
            showDefinition(for: text, at: NSPoint(x: point.x, y: bounds.height - point.y))
        case .replace(let word):
            Task { @MainActor in _ = try? await navigationRequest("page.replaceMisspelling", ["text": .string(word)]) }
        case .back: tab.back()
        case .forward: tab.forward()
        case .reload: tab.reload()
        case .selectionCommand(let id): tab.onSelectionCommand?(tab, id)
        case .saveMedia(let url):
            let pointed = tab.pointedMedia.flatMap { CACurrentMediaTime() - $0.at < 30 ? $0.media : nil }
            tab.onMediaSave?(tab, VideoSave.pointed(source: url, heard: pointed, audio: audio))
        case .capture: tab.onCapturePage?(tab)
        case .hide:
            let zoom = max(pageZoom * magnification, 0.01)
            tab.page.runInYab("window.__yabVeil && window.__yabVeil.at(\(point.x / zoom), \(point.y / zoom))")
        }
    }

    /// Through Chromium's own download manager, so the file arrives in the
    /// downloads list with the page's cookies, as any other of this tab's.
    func startDownload(_ url: URL) {
        ChromiumDownload.ask(url, on: self)
        Task { @MainActor in _ = try? await navigationRequest("page.download", ["url": .string(url.absoluteString)]) }
    }

    /// The picture's pixels, decoded by Chromium from its own fetch: as
    /// PNG, the picture as it is, or for reading its words, no longer than
    /// `largest` pixels and as JPEG, which a photograph's words survive.
    /// They come in a file of this user's own, not through the wire every
    /// page's requests share (YabCore's ImageBytes, #1991); a helper from
    /// before that still answers in the wire.
    func imageData(_ url: URL, largest: Int? = nil) async -> Data? {
        var params: [String: JSONValue] = ["url": .string(url.absoluteString), "delivery": .string("file")]
        if let largest { params["maxPixels"] = .number(Double(largest)); params["format"] = .string("jpeg") }
        guard let value = try? await navigationRequest("page.imageData", params) else { return nil }
        if let path = value["file"].string { return await Self.takeImageFile(path) }
        guard let encoded = value["jpeg"].string ?? value["png"].string else { return nil }
        return Data(base64Encoded: encoded)
    }

    /// The helper's picture file, read and removed off the main thread.
    /// Only a yab-image- file in this user's temporary folder is taken.
    nonisolated static func takeImageFile(_ path: String) async -> Data? {
        await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let folder = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.resolvingSymlinksInPath()
            guard url.lastPathComponent.hasPrefix("yab-image-"),
                  url.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.path else { return nil }
            defer { try? FileManager.default.removeItem(at: url) }
            return try? Data(contentsOf: url)
        }.value
    }
}
