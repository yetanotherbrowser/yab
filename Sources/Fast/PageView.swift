import ImageIO
import Combine
import ObjectiveC
import SwiftUI
import WebKit

/// A web view that reads the two-finger swipe for itself.
final class PageView: QuietWebView, NSTextContent {
    // Retained here because WebKit holds its navigation delegate weakly.
    let navigationEvents = WebKitPageEvents()
    let stateObservation = WebKitPageState()
    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        AppleWritingTools.configure(configuration)
        super.init(frame: frame, configuration: configuration)
        // A click's activation outlives scripts run in the page (QuietScript).
        keepActivationThroughScripts()
        // Paused as the Mac goes to sleep, so waking plays nothing (#263).
        SleepHush.shared.pages.add(self)
    }

    override func stopLoading() {
        navigationEvents.stopLoadRetry(self)
        super.stopLoading()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // Every caller, Swift or Objective-C, goes through MediaPresentationClose:
    // WebKit keeps this call's completion block without retaining it.
    override func closeAllMediaPresentations(completionHandler: (@MainActor @Sendable () -> Void)? = nil) {
        MediaPresentationClose.send(self, then: completionHandler)
    }

    override func addTrackingArea(_ area: NSTrackingArea) {
        super.addTrackingArea(PageHoverTracking.wrap(area, in: self))
    }

    override func removeTrackingArea(_ area: NSTrackingArea) {
        if let entry = PageHoverTracking.take(area, from: self) {
            super.removeTrackingArea(entry.area)
            withExtendedLifetime(entry) {}
        } else { super.removeTrackingArea(area) }
    }

    // Before the first focus report arrives there is no known text field.
    // nil lets AppKit guess and offer an SMS code even in a login's email.
    @objc var contentType: NSTextContentType? = .URL {
        didSet {
            guard contentType != oldValue else { return }
            // Focus reaches this relay after WebKit's selection update.
            // Refresh the native context so an earlier code hint goes away.
            inputContext?.invalidateCharacterCoordinates()
        }
    }

    func updateInputContent(_ kind: String?) {
        switch kind {
        case "email": contentType = .emailAddress
        case "username": contentType = .username
        case "password": contentType = .password
        case "new-password": contentType = .newPassword
        case "code": contentType = .oneTimeCode
        case "phone": contentType = .telephoneNumber
        case "text": contentType = nil
        default: contentType = .URL
        }
    }

    // MARK: - its own undo

    /// The page's typing undoes in the page, never in the window. WebKit
    /// files each edit in its view's undoManager, the window's by default,
    /// with a target that lives only as long as the view, and takes them
    /// out again on close through the same undoManager. A tab closed or put
    /// to sleep while not in front has no window by then, so its edits
    /// stayed in the window's undo, and ⌘Z on another page sent undoEditing:
    /// to freed memory (crash #8, 0.0.8). Kept with the view, they go with
    /// it, and ⌘Z on one page no longer reaches into another.
    private let edits = UndoManager()
    override var undoManager: UndoManager? { edits }

    /// ⌘Z and ⇧⌘Z stop at the page. The Edit menu's undo: goes up to the
    /// window, which undoes in the first text view's or its own manager on
    /// the way up and never asks a view's undoManager: with a page in front,
    /// ⌘Z undid the window's undo instead of the page's typing, and reached
    /// whatever the window still held, a closed reply's keys with their
    /// words freed (0.0.9). Answered here, a page's ⌘Z undoes only the page.
    @objc func undo(_ sender: Any?) { edits.undo() }
    @objc func redo(_ sender: Any?) { edits.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = edits.undoMenuItemTitle
            return edits.canUndo
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = edits.redoMenuItemTitle
            return edits.canRedo
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: - where it was scrolled

    /// How far down the page is scrolled, in CSS pixels, as the page last
    /// said (Tab.scrolled): a still of it is shown only at the same place
    /// (PageStills.Key).
    var scrollTop: Double = 0

    // MARK: - seen off screen

    /// WebKit calls a page hidden when no part of its window is on a
    /// screen, and a hidden page runs no animation frames and slow timers:
    /// in the bench's room, off every screen, an agent's page did neither,
    /// and lazy lists and some apps waited for a frame that never came.
    /// The quiet name tells WebKit not to judge by the window, so the page
    /// counts as seen; only for as long as an agent works in it.
    private static let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
    static let canSee = WKWebView.instancesRespond(to: occlusion)

    var seenOffscreen = false {
        didSet {
            guard seenOffscreen != oldValue, Self.canSee else { return }
            typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(method(for: Self.occlusion), to: Set.self)(self, Self.occlusion, !seenOffscreen)
        }
    }

    /// Seen in a window of its own that is on no screen for now (Bench.see).
    var keepSeen = false

    /// Taken to a window someone can see, the page is judged by it again.
    /// Once, the next time the view is put in a window (Tab.loadAndVerify).
    var onWindow: (() -> Void)?
    var videoOpeningWatches: Set<AnyCancellable> = []

    override func layout() {
        super.layout()
        updateVideoOpening()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        navigationEvents.resumeNetworkLoad()
        updateVideoOpening()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateVideoOpening()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        giveUpKeys(leavingFor: newWindow)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        navigationEvents.resumeNetworkLoad()
        windowClick = WindowClick()
        PageFullScreenMove.moved(self)
        updateVideoOpening()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.updateVideoOpening() } }
        if window != nil, let onWindow {
            self.onWindow = nil
            onWindow()
        }
        if seenOffscreen, !keepSeen, window?.identifier != Bench.roomID { seenOffscreen = false }
        if window == nil {
            tip.end()
            glide.stop()
            // A call sharing what Yab takes itself has to keep drawing (Bench.keepSharing).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window == nil else { return }
                Share.shared.keepDrawing(self)
            }
        }
    }

    // MARK: - the page's own tooltips

    private lazy var tip = PageTip(page: self)

    /// WebKit says a page has a new tooltip, a title="" under the pointer,
    /// by giving the view one over the whole page, for the system to draw.
    /// Taken here, the system never has it, and the tip is drawn as every
    /// tip in yab is (PageTip). The tag is never asked for again: WebKit
    /// takes its tips down all at once.
    override func addToolTip(_ rect: NSRect, owner: Any, userData data: UnsafeMutableRawPointer?) -> NSView.ToolTipTag {
        guard PageTip.can else { return super.addToolTip(rect, owner: owner, userData: data) }
        tip.changed()
        return 1
    }

    /// What extensions added to the right-click menu, at the end of it.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        selectionTurn &+= 1
        let selectionGeneration = selectionTurn
        selectionMenu = nil
        wrapContextLink(in: menu, event: event)
        defer {
            Self.dress(menu)
            linkRowsHere(menu)
            Self.menuWatch?(menu)
        }
        if let (user, linked) = onAppleCodeContext?() {
            let title = linked ? "Open Apple Passwords for \(user)" : "Use Apple Passwords for \(user)…"
            let item = NSMenuItem(title: title, action: #selector(openAppleCode(_:)), keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier("YabApplePasswords")
            menu.addItem(.separator())
            menu.addItem(item)
        }
        let source = url
        // Go To for a selected web address, from the words read before
        // WebKit showed the menu (readBeforeMenu): a row put into a menu
        // already up is drawn over its neighbors.
        let read = Self.currentMenuWords(menuWords, source: source)
        menuWords = nil
        let goTo = { [weak self] (words: String) in
            guard let self, let item = SelectedURLMenu.insert(words, source: source, into: menu, target: self,
                                                              action: #selector(self.goToSelection(_:))) else { return }
            MenuMark.put(Self.marks["WKMenuItemIdentifierOpenLink"], on: item)
        }
        // WebKit's Search with Google hands the words to the Mac's default
        // browser. Here it is the engine picked in Settings, in a tab beside
        // this one, private from a private tab.
        if let item = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierSearchWeb" }) {
            selection = read?.words
            selectionMenu = menu
            if let read { goTo(read.words) }
            PageView.readSelected(in: self) { [weak self, weak menu] words in
                guard let self, let menu, self.selectionTurn == selectionGeneration,
                      self.selectionMenu === menu, self.url == source else { return }
                self.selection = words
            }
            item.title = "Search with \(searchName?() ?? Engine.name)"
            item.target = self
            item.action = #selector(searchSelection(_:))
        } else if let read, let link = read.link, SelectedURLMenu.url(read.words, besides: link) != nil {
            // WebKit's menu for a link has no rows for words selected in it.
            goTo(read.words)
        }
        let commands = onSelectionMenu?() ?? []
        if let search = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierSearchWeb" }) {
            var index = menu.index(of: search) + 1
            menu.insertItem(.separator(), at: index)
            index += 1
            for command in commands {
                menu.insertItem(selectionMenuItem(command), at: index)
                index += 1
            }
            // Its key where a menu teaches keys, on the item it opens.
            let key = Keymap.shared.keys(.agentAsk)
            let more = NSMenuItem(title: "More Commands\u{2026}", action: #selector(runSelectionCommand(_:)),
                                  keyEquivalent: key.map { $0.key.count == 1 ? $0.key : "" } ?? "")
            if let key, key.key.count == 1 { more.keyEquivalentModifierMask = key.flags }
            more.target = self
            menu.insertItem(more, at: index)
        }
        menuAt = CACurrentMediaTime()
        emailHere(menu, since: menuAt)
        imagesHere(menu, with: event)
        mediaHere(menu, since: menuAt, document: audioDocument)
        wordsHere(menu)
        hideHere(menu, event)
        Self.appendPageTranslation(to: menu, selectedWords: read?.words) { onTranslationMenu?() ?? [] }
        captureHere(menu)
        inspectHere(menu, event)
        guard #available(macOS 15.4, *),
              let tab = Extensions.shared.tab(showing: self)
        else { return }
        let extensions = Extensions.of(tab: tab)
        PageExtensionMenus.append(to: menu, nativeController: configuration.webExtensionController,
                                  owner: extensions.controller) {
            let items = extensions.menuItems(for: tab)
            // Only the fallback's rows need decorating here. WebKit owns
            // the same controller's native rows, with their hit-test context.
            for item in items {
                if item.image == nil { item.image = MenuMark.image("puzzlepiece.extension") }
                MenuMark.show(item)
            }
            return items
        }
    }

    func selectionMenuItem(_ command: SelectionCommand) -> NSMenuItem {
        let item = NSMenuItem(title: SelectionCommand.menuTitle(command.name), action: #selector(runSelectionCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command.id
        return item
    }

    /// Page translation belongs to the ordinary page menu. WebKit's native
    /// selection rows, including an editable field's enabled Copy/Cut, or
    /// words freshly read inside a link keep this menu scoped to selection.
    static func appendPageTranslation(to menu: NSMenu, selectedWords: String?, items: () -> [NSMenuItem]) {
        let selecting = menu.items.contains { item in
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierSearchWeb", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierTranslate": true
            case "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCut": item.isEnabled
            default: false
            }
        } || !(selectedWords?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard !selecting else { return }
        let translation = items()
        guard !translation.isEmpty else { return }
        menu.addItem(.separator())
        translation.forEach(menu.addItem)
    }

    /// WebKit's own reading of the page's pictures:
    /// the words in them become text a person can select by hand, as Live
    /// Text does in Photos. False where this WebKit has no such ask.
    @discardableResult
    func lookAtPictures() -> Bool {
        let ask = NSSelectorFromString("_startImageAnalysis:target:")
        guard responds(to: ask) else { return false }
        perform(ask, with: nil, with: nil)
        return true
    }

    /// Shown every right-click menu once it is dressed: the bench's look
    /// at what it holds (BenchPointer).
    static var menuWatch: ((NSMenu) -> Void)?

    // The native new-window row still owns the URL and WebKit context. Only
    // its tab-selection intent is carried across the asynchronous delegate.
    private var contextLink: (url: URL, source: URL?, at: Double)?
    private final class ContextLinkAction: NSObject {
        weak var target: AnyObject?
        let action: Selector
        init(target: AnyObject?, action: Selector) { self.target = target; self.action = action }
    }
    private static var contextLinkActionKey: UInt8 = 0
    private weak var contextLinkItem: NSMenuItem?
    private var contextMenuStarted: Double = .infinity
    private var contextMenuSource: URL?
    private var contextMenuFlags: NSEvent.ModifierFlags = []
    private var menuOpen: (id: UUID, url: URL, source: URL?, until: TimeInterval, foreground: Bool)?

    func heardContextLink(_ link: String, at: Double) {
        contextLink = URL(string: link).flatMap { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? (url, self.url, at) : nil
        }
    }

    func clearMenuOpen() {
        menuOpen = nil
        contextLink = nil
    }

    private func wrapContextLink(in menu: NSMenu, event: NSEvent) {
        menuOpen = nil
        // The DOM clock is milliseconds since the epoch, the native event's
        // is uptime. An earlier contextmenu receipt cannot stand in for this one.
        contextMenuStarted = floor((Date().timeIntervalSince1970 - (ProcessInfo.processInfo.systemUptime - event.timestamp)) * 1000)
        contextMenuSource = url
        contextMenuFlags = event.modifierFlags
        contextLinkItem = nil
        guard let item = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) else { return }
        if item.action != #selector(openContextLink(_:)) {
            guard let action = item.action else { return }
            let original = ContextLinkAction(target: item.target, action: action)
            objc_setAssociatedObject(item, &Self.contextLinkActionKey, original, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        guard objc_getAssociatedObject(item, &Self.contextLinkActionKey) is ContextLinkAction else { return }
        contextLinkItem = item
        item.target = self
        item.action = #selector(openContextLink(_:))
    }

    @objc private func openContextLink(_ item: NSMenuItem) {
        guard contextLinkItem === item,
              let command = objc_getAssociatedObject(item, &Self.contextLinkActionKey) as? ContextLinkAction else { return }
        menuOpen = nil
        if let link = currentContextLink {
            // Shift at either the context press or the native selection is
            // an explicit request to show the destination.
            let flags = (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).union(contextMenuFlags)
            let id = UUID()
            menuOpen = (id, link, url, ProcessInfo.processInfo.systemUptime + 1, flags.contains(.shift))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                if self?.menuOpen?.id == id { self?.menuOpen = nil }
            }
        }
        // Forward the original item, including WebKit's represented context.
        if !NSApp.sendAction(command.action, to: command.target, from: item) { menuOpen = nil }
    }

    /// The link menu's Open in Split View: what ⌥-click on the link does
    /// (Browser.splitLink), under Open Link in New Tab, as Arc had it
    /// (feedback #1900). The same row on Chromium tabs (ChromiumMenuRow).
    static let splitLinkTitle = "Open in Split View"
    static let splitLinkID = "YabOpenLinkInSplitView"
    /// Puts a link in Split View beside this page's tab.
    var onSplitLink: ((URL) -> Void)?

    /// The link menu's Open Link in Private Window, under Open in Split
    /// View: a private window of its own, as ⇧⌘N opens. Not from a private
    /// tab, whose new tab rows already stay private.
    static let privateLinkTitle = "Open Link in Private Window"
    static let privateLinkID = "YabOpenLinkInPrivateWindow"
    /// Opens a link in a new private window.
    var onPrivateLink: ((URL) -> Void)?

    /// Open in Split View, then Open Link in Private Window, under Open Link
    /// in New Tab, each where this page has somewhere to send the link.
    private func linkRowsHere(_ menu: NSMenu) {
        guard let tab = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) else { return }
        var index = menu.index(of: tab)
        let rows: [(on: Bool, title: String, id: String, action: Selector)] = [
            (onSplitLink != nil, Self.splitLinkTitle, Self.splitLinkID, #selector(splitContextLink(_:))),
            (onPrivateLink != nil, Self.privateLinkTitle, Self.privateLinkID, #selector(privateContextLink(_:))),
        ]
        for row in rows where row.on && !menu.items.contains(where: { $0.identifier?.rawValue == row.id }) {
            let item = NSMenuItem(title: row.title, action: row.action, keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier(row.id)
            MenuMark.put(Self.marks[row.id], on: item)
            index += 1
            menu.insertItem(item, at: index)
        }
    }

    /// The page's contextmenu event's link for this press, as Open Link in
    /// New Tab reads it, or nil when none was heard for it.
    private var currentContextLink: URL? {
        guard let link = contextLink, link.at >= contextMenuStarted, link.source == url, contextMenuSource == url else { return nil }
        return link.url
    }

    /// Without the page's link (a link that isn't the web's), the new tab
    /// row's own action.
    @objc private func splitContextLink(_ item: NSMenuItem) {
        if let link = currentContextLink {
            contextLink = nil
            onSplitLink?(link)
        } else if let tab = contextLinkItem {
            openContextLink(tab)
        }
    }

    /// Without the page's link, nothing opens: a link that isn't the web's
    /// has no business in a private window.
    @objc private func privateContextLink(_ item: NSMenuItem) {
        guard let link = currentContextLink else { return }
        contextLink = nil
        onPrivateLink?(link)
    }

    func takeMenuOpen(for destination: URL?) -> Bool? {
        defer { menuOpen = nil }
        guard let intent = menuOpen, intent.url == destination, intent.source == url,
              ProcessInfo.processInfo.systemUptime <= intent.until else { return nil }
        return intent.foreground
    }

    // MARK: - marks in the menu

    /// WebKit's rows by their ids, each in the drawing the app wears for
    /// the same thing elsewhere, ⌘K's most often. The new tab rows wear a
    /// tab over a tab, not ⌘K's bare plus: that one says an empty tab, these
    /// a page going into one. WebKit gives them SF Symbols of its own,
    /// Safari's compass on Open Link among them.
    static let marks: [String: String] = [
        "WKMenuItemIdentifierOpenLink": "yab.arrowout",
        "WKMenuItemIdentifierOpenLinkInNewWindow": "yab.tab.plus",
        "YabOpenLinkInSplitView": "rectangle.split.2x1",
        "YabOpenLinkInPrivateWindow": "incognito",
        "WKMenuItemIdentifierDownloadLinkedFile": "yab.download",
        "WKMenuItemIdentifierCopyLink": "link",
        "WKMenuItemIdentifierCopyLinkWithHighlight": "yab.text",
        "WKMenuItemIdentifierOpenImageInNewWindow": "plus.rectangle.on.rectangle",
        "WKMenuItemIdentifierDownloadImage": "arrow.down.circle",
        "WKMenuItemIdentifierCopyImage": "yab.copyframe.image",
        "WKMenuItemIdentifierRevealImage": "visual.intelligence",
        "WKMenuItemIdentifierCopySubject": "sticker",
        "YabCopyText": "yab.copyframe.text",
        "YabAskAboutImage": "yab.chat.spark",
        "WKMenuItemIdentifierOpenMediaInNewWindow": "yab.video.out",
        "WKMenuItemIdentifierDownloadMedia": "yab.video.dl",
        "YabDownloadMedia": "yab.video.dl",
        "YabDownloadAudio": "yab.audio.dl",
        "WKMenuItemIdentifierCopyMediaLink": "yab.copyframe.link",
        "WKMenuItemIdentifierOpenFrameInNewWindow": "yab.window.out",
        "WKMenuItemIdentifierLookUp": "info.circle",
        "WKMenuItemIdentifierTranslate": "yab.translate",
        "WKMenuItemIdentifierSearchWeb": "magnifyingglass",
        "WKMenuItemIdentifierCopy": "yab.copyframe.text",
        "WKMenuItemIdentifierPaste": "yab.clipboard",
        "WKMenuItemIdentifierShareMenu": "yab.share",
        "WKMenuItemIdentifierSpeechMenu": "yab.speaker",
        "WKMenuItemIdentifierGoBack": "yab.back",
        "WKMenuItemIdentifierGoForward": "yab.forward",
        "WKMenuItemIdentifierReload": "yab.reload",
        "WKMenuItemIdentifierInspectElement": "yab.code",
        "YabMeasure": "yab.ruler",
        "YabCaptureImage": "camera",
        "YabCapturePage": "camera",
        "YabCopyImageAddress": "yab.copyframe.link",
        "YabCopyEmailAddress": "yab.copyframe.at",
        "YabHideElement": "yab.eye.slash",
        "YabTranslatePage": "yab.translate",
        "YabApplePasswords": "key",
    ]

    /// Every row in the app's own drawing, and each picture once: a row
    /// doing again what a row above it drew, Download Image under Download
    /// Linked File, is text in the titles' column, the way Apple's menus
    /// leave a variant. A row this doesn't know, one a later macOS adds,
    /// keeps WebKit's symbol; one with no picture at all, Services, keeps
    /// the titles' column too.
    static func dress(_ menu: NSMenu) {
        // A link's new tab row first: a plain click
        // already opens the link here (feedback #201).
        let row = { (id: String) in menu.items.first { $0.identifier?.rawValue == "WKMenuItemIdentifier" + id } }
        if let open = row("OpenLink"), let tab = row("OpenLinkInNewWindow"), menu.index(of: tab) > menu.index(of: open) {
            menu.removeItem(tab)
            menu.insertItem(tab, at: menu.index(of: open))
        }
        var drawn = Set<String>()
        for item in menu.items where !item.isSeparatorItem {
            let id = item.identifier?.rawValue ?? ""
            // WebKit's "New Window" opens a tab here (Browser's
            // createWebViewWith), and says so.
            if id.hasSuffix("InNewWindow") {
                item.title = item.title.replacingOccurrences(of: "New Window", with: "New Tab")
            }
            let mark: String?
            if let name = marks[id] {
                mark = name
            } else if item.action == #selector(PageView.runSelectionCommand(_:)) {
                // A command wears its mark from the selection's panel;
                // More Commands… has none to wear.
                mark = (item.representedObject as? String).map(SelectionLayer.symbol)
            } else {
                continue
            }
            // Native Translate and the selection's own Translate command
            // both need their mark. Other repeated pictures stay deduped.
            let selectionTranslation = id == "WKMenuItemIdentifierTranslate"
                || (item.action == #selector(PageView.runSelectionCommand(_:)) && (item.representedObject as? String) == "translate")
            guard let mark, !drawn.contains(mark) || selectionTranslation else {
                item.image = nil
                continue
            }
            drawn.insert(mark)
            MenuMark.put(mark, on: item)
        }
        guard menu.items.contains(where: { $0.image != nil }) else { return }
        for item in menu.items where !item.isSeparatorItem && item.image == nil {
            MenuMark.put(nil, on: item)
        }
    }

    var onSearch: ((String) -> Void)?
    var onSelectedURL: ((URL, NSEvent.ModifierFlags) -> Void)?
    /// What Search with… calls the engine: the one of the tab's space.
    var searchName: (() -> String)?
    /// Measure on a development page with the tools closed, picking what
    /// was right-clicked. Nil where Measure's row is unavailable.
    var onMeasure: (() -> ((CGPoint) -> Void)?)?
    /// Make room for Inspect Element, then run WebKit's original action
    /// once the inspector's attachment dock has entered its window.
    var onWebInspect: ((@escaping () -> Void) -> Void)?
    /// A row of the picture's menu picked (ImageMenu.swift), and when the
    /// menu opened: false where no picture of this right-click was heard,
    /// and WebKit's own row does it. The final value is whether Open Image
    /// was requested in front, including the menu's Command/Shift intent.
    var onImage: ((ImageAct, CFTimeInterval, Bool) -> Bool)?
    var onCapture: (() -> Void)?
    /// Download Video (or Audio) picked, and when the menu opened: false
    /// where no video of this right-click was heard (VideoSave.swift).
    var onMedia: ((CFTimeInterval) -> Bool)?
    /// The video or sound this right-click landed on, when its page said.
    var mediaHeard: ((CFTimeInterval) -> PointedMedia?)?
    /// The words of the picture right-clicked, by when the menu opened:
    /// read already, or still being read, or neither.
    var onPictureWords: ((CFTimeInterval) -> (now: PictureWords?, later: (() async -> PictureWords?)?))?
    var onPictureCopied: (() -> Void)?
    /// The mailto: link this right-click landed on, heard from the page's
    /// contextmenu event since the menu opened (less a second), if any.
    var onMailLink: ((CFTimeInterval) -> URL?)?
    /// Whether this page's pictures can be asked about: not a private tab's.
    var picturesAskable: (() -> Bool)?
    private var pictureText = ""
    private weak var wordsMenu: NSMenu?
    private var webImage: [String: (target: AnyObject?, action: Selector?, act: ImageAct)] = [:]
    private var imageMenuFlags: NSEvent.ModifierFlags = []
    private var menuAt: CFTimeInterval = 0
    /// Hide Element: what is at this point of the page, taken off it for
    /// good on this site, as Hide Elements does once pointed at (Curtain).
    var onHideAt: ((CGPoint) -> Void)?
    private var hidePoint = CGPoint.zero
    private var inspectPoint = CGPoint.zero
    private var webInspect: (target: AnyObject?, action: Selector?) = (nil, nil)
    var onSelectionCommand: ((String?) -> Void)?
    var onSelectionMenu: (() -> [SelectionCommand])?
    var onTranslationMenu: (() -> [NSMenuItem])?
    var onAppleCodeContext: (() -> (String, Bool)?)?
    var onAppleCodeOpen: (() -> Void)?
    var onSelectionPause: (() -> Void)?
    private var selection: String?
    private weak var selectionMenu: NSMenu?
    private var selectionTurn: UInt = 0
    typealias MenuWords = (words: String, link: String?, source: URL?, at: CFTimeInterval)
    private var menuWords: MenuWords?

    static func currentMenuWords(_ words: MenuWords?, source: URL?, now: CFTimeInterval = CACurrentMediaTime()) -> MenuWords? {
        words.flatMap { $0.source == source && now - $0.at < 3 ? $0 : nil }
    }
    /// The menu WebKit is holding back for the read below, if any.
    private var menuRead: MenuRead?

    /// WebKit's completion for one held menu, called exactly once.
    /// Dropped uncalled, WebKit's CompletionHandlerCallChecker throws as
    /// the block goes, and the browser aborts (crash #1124: a second
    /// right-click on the page before the first menu's read ended).
    @MainActor final class MenuRead {
        private var done: (@MainActor (Bool) -> Void)?
        init(_ done: @escaping @MainActor (Bool) -> Void) { self.done = done }
        var pending: Bool { done != nil }
        /// `current`: still the page's newest menu, to be shown as it is.
        func finish(current: Bool) {
            let done = self.done
            self.done = nil
            done?(current)
        }
    }

    /// The words selected, read while WebKit holds its menu back for
    /// Browser's getContextMenuFromProposedMenu, so the rows made from them
    /// are in the menu as it opens. In a link's menu only words selected
    /// inside that link count, with the link's address. Never more than a
    /// quarter of a second: the menu is not held for a slow page.
    /// A menu asked for while another is still held answers the older
    /// one first, as no longer current (`done(false)`): WebKit's menu for it
    /// is gone, and its completion must still be called.
    func readBeforeMenu(_ menu: NSMenu, _ done: @escaping @MainActor (_ current: Bool) -> Void) {
        menuWords = nil
        menuRead?.finish(current: false)
        menuRead = nil
        let source = url
        let ids = Set(menu.items.compactMap { $0.identifier?.rawValue })
        let search = ids.contains("WKMenuItemIdentifierSearchWeb")
        guard search || ids.contains("WKMenuItemIdentifierCopyLink") else { done(true); return }
        let read = MenuRead(done)
        menuRead = read
        let finish: @MainActor (String, String?) -> Void = { [weak self] words, link in
            guard read.pending else { return }
            if let self, self.menuRead === read {
                self.menuRead = nil
                if self.url == source, !words.isEmpty { self.menuWords = (words, link, source, CACurrentMediaTime()) }
            }
            read.finish(current: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { finish("", nil) } }
        if search {
            // A PDF's words no page script sees are asked of WebKit itself.
            PageView.readSelected(in: self) { [weak self] words in
                finish(words.isEmpty ? self.map(Self.webKitSelection) ?? "" : words, nil)
            }
        } else {
            evaluateJavaScript(SelectedURLMenu.selectedInLink, in: nil, in: .defaultClient) { result in
                MainActor.assumeIsolated {
                    let pair = (try? result.get()) as? [String]
                    finish(pair?.first ?? "", pair?.last)
                }
            }
        }
    }

    /// The words selected where the right-click was, read as the menu
    /// opens. A text field's selection is its own, not the page's, so a field
    /// with the caret is asked first; a frame with the caret is looked into
    /// when it is of the same site, a shadow root's words through the
    /// composed range. One of another site is read in its own document
    /// (readSelected(in:)). A password field gives nothing.
    static let selected = """
    (function read(doc) {
      var el = doc.activeElement;
      while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
      if (el && /^(IFRAME|FRAME)$/.test(el.tagName)) {
        try { return el.contentDocument ? read(el.contentDocument) : ''; } catch (e) { return ''; }
      }
      if (el && (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && el.type !== 'password'))) {
        try {
          var from = el.selectionStart, to = el.selectionEnd;
          if (typeof from === 'number' && typeof to === 'number' && to > from) return el.value.slice(from, to);
        } catch (e) {}
      }
      if (el && el.tagName === 'INPUT' && el.type === 'password') return '';
      var s = doc.getSelection();
      var flat = s ? s.toString() : '';
      if (flat.trim() || !s || !s.rangeCount || !s.getComposedRanges) return flat;
      var roots = [], seen = 0;
      (function walk(w) { for (var n = w.nextNode(); n && seen++ < 30000; n = w.nextNode()) if (n.shadowRoot) {
        roots.push(n.shadowRoot); walk(doc.createTreeWalker(n.shadowRoot, NodeFilter.SHOW_ELEMENT)); } })(doc.createTreeWalker(doc, NodeFilter.SHOW_ELEMENT));
      if (!roots.length) return flat;
      try {
        var at = s.getComposedRanges({ shadowRoots: roots })[0];
        if (!at || at.collapsed) return flat;
        var r = doc.createRange(); r.setStart(at.startContainer, at.startOffset); r.setEnd(at.endContainer, at.endOffset);
        return r.toString();
      } catch (e) { return flat; }
    })(document)
    """

    /// The words selected in the page, or else in one of its frames: of
    /// another site's too, asked in each frame's own document. The
    /// focused frame's first; "" when nothing is selected anywhere.
    static func readSelected(in web: WKWebView, _ done: @escaping @MainActor (String) -> Void) {
        web.evaluateJavaScript(selected, in: nil, in: .defaultClient) { [weak web] result in
            MainActor.assumeIsolated {
                let words = (try? result.get()) as? String ?? ""
                guard words.isEmpty, let web else { done(words); return }
                web.webKitSubframes { infos in
                    var found: [(focused: Bool, words: String)] = []
                    let group = DispatchGroup()
                    for info in infos {
                        group.enter()
                        web.evaluateJavaScript("[\(selected), document.hasFocus()]", in: info, in: .defaultClient) { result in
                            MainActor.assumeIsolated {
                                if let pair = (try? result.get()) as? [Any], let words = pair.first as? String, !words.isEmpty {
                                    found.append((pair.last as? Bool == true, words))
                                }
                                group.leave()
                            }
                        }
                    }
                    group.notify(queue: .main) {
                        MainActor.assumeIsolated { done((found.first(where: \.focused) ?? found.first)?.words ?? "") }
                    }
                }
            }
        }
    }

    /// The selection as WebKit writes it for a service, onto a pasteboard
    /// of its own: "" when there is none.
    static func webKitSelection(of web: WKWebView) -> String {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.serafim.fast.search-selection"))
        defer { board.releaseGlobally() }
        board.clearContents()
        // WKWebView answers Services so, though its header doesn't say.
        let ask = NSSelectorFromString("writeSelectionToPasteboard:types:")
        guard web.responds(to: ask) else { return "" }
        typealias Write = @convention(c) (AnyObject, Selector, NSPasteboard, NSArray) -> Bool
        let write = unsafeBitCast(web.method(for: ask), to: Write.self)
        guard write(web, ask, board, [NSPasteboard.PasteboardType.string.rawValue] as NSArray) else { return "" }
        return board.string(forType: .string) ?? ""
    }

    @objc private func goToSelection(_ item: NSMenuItem) {
        guard let destination = item.representedObject as? SelectedURLMenu.Destination,
              destination.source == url else { return }
        let flags = (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).union(contextMenuFlags)
        onSelectedURL?(destination.url, flags)
    }

    @objc private func searchSelection(_ item: NSMenuItem) {
        defer { selection = nil }
        // Words a page script can't see (a closed shadow root, a PDF, the
        // read not back yet) are asked of WebKit itself, as Services asks
        // it. WebKit's own row is never pressed: it hands the words to
        // Safari's Search With service (feedback #329).
        let read = selection.flatMap { $0.isEmpty ? nil : $0 } ?? Self.webKitSelection(of: self)
        let words = read.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { onSearch?(words) }
    }

    /// Inspect Element always goes to WebKit, with Measure put away first.
    /// Measure has its own row just below, where it is available.
    func inspectHere(_ menu: NSMenu, _ event: NSEvent) {
        guard let item = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierInspectElement" }) else { return }
        webInspect = (item.target, item.action)
        let at = convert(event.locationInWindow, from: nil)
        let zoom = max(pageZoom * magnification, 0.01)
        inspectPoint = CGPoint(x: at.x / zoom, y: (isFlipped ? at.y : bounds.height - at.y) / zoom)
        item.target = self
        item.action = #selector(inspectElement(_:))
        if onMeasure?() != nil {
            let measure = NSMenuItem(title: "Measure", action: #selector(measureElement(_:)), keyEquivalent: "")
            measure.target = self
            measure.identifier = NSUserInterfaceItemIdentifier("YabMeasure")
            menu.insertItem(measure, at: menu.index(of: item) + 1)
        }
    }

    /// Copy Email Address under WebKit's Copy Link on a mailto: link, as
    /// Chrome has it (feedback #164): the address alone, quietly, as Copy
    /// Link copies. The link is the
    /// page's contextmenu event's, heard just before the menu opens, or a
    /// moment after, when the row comes into the open menu. Neither Chrome
    /// nor Safari has a row of its own for a tel: link, so there is none.
    private func emailHere(_ menu: NSMenu, since: CFTimeInterval, again: Bool = true) {
        guard let copy = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyLink" }),
              !menu.items.contains(where: { $0.identifier?.rawValue == "YabCopyEmailAddress" }) else { return }
        guard let link = onMailLink?(since), let address = Self.emailAddress(link) else {
            if again {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak menu] in
                    guard let self, let menu else { return }
                    self.emailHere(menu, since: since, again: false)
                    Self.dress(menu)
                }
            }
            return
        }
        let item = NSMenuItem(title: "Copy Email Address", action: #selector(copyEmailAddress(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = address
        item.identifier = NSUserInterfaceItemIdentifier("YabCopyEmailAddress")
        menu.insertItem(item, at: copy + 1)
    }

    /// What Copy Email Address copies: no "mailto:", and
    /// nothing from "?" on (a subject, a Cc); escapes undone. Nil for a
    /// link that names nobody.
    static func emailAddress(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let rest = String(url.absoluteString.dropFirst("mailto:".count))
        let bare = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let address = (bare.removingPercentEncoding ?? bare).trimmingCharacters(in: .whitespaces)
        return address.isEmpty ? nil : address
    }

    @objc private func copyEmailAddress(_ item: NSMenuItem) {
        guard let address = item.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }

    /// WebKit's rows for a picture, done by Yab (ImageMenu.swift), and Copy
    /// Image Address after Copy Image.
    private func imagesHere(_ menu: NSMenu, with event: NSEvent) {
        imageMenuFlags = event.modifierFlags
        webImage = [:]
        guard onImage != nil else { return }
        let rows: [(String, ImageAct)] = [
            ("WKMenuItemIdentifierOpenImageInNewWindow", .open),
            ("WKMenuItemIdentifierCopyImage", .copy),
            ("WKMenuItemIdentifierDownloadImage", .download),
        ]
        for (id, act) in rows {
            guard let item = menu.items.first(where: { $0.identifier?.rawValue == id }) else { continue }
            // WebKit's representedObject stays: WKMenuTarget reads it when
            // the row is forwarded, and traps on anything else.
            webImage[id] = (item.target, item.action, act)
            item.target = self
            item.action = #selector(imageRow(_:))
        }
        if let copy = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyImage" }) {
            let item = NSMenuItem(title: "Copy Image Address", action: #selector(imageRow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ImageAct.address.rawValue
            item.identifier = NSUserInterfaceItemIdentifier("YabCopyImageAddress")
            menu.insertItem(item, at: copy + 1)
            let capture = NSMenuItem(title: "Capture Image", action: #selector(imageRow(_:)), keyEquivalent: "")
            capture.target = self
            capture.representedObject = ImageAct.capture.rawValue
            capture.identifier = NSUserInterfaceItemIdentifier("YabCaptureImage")
            menu.insertItem(capture, at: copy + 1)
            // Ask About Image, after what WebKit and Yab do with the picture
            // itself, with ⌘J's key, as More Commands… wears it.
            if picturesAskable?() == true {
                let rows = ["YabCopyImageAddress", "WKMenuItemIdentifierCopySubject", "WKMenuItemIdentifierRevealImage"]
                let last = menu.items.lastIndex { rows.contains($0.identifier?.rawValue ?? "") } ?? copy + 1
                let key = Keymap.shared.keys(.agentAsk)
                let ask = NSMenuItem(title: "Ask About Image", action: #selector(imageRow(_:)),
                                     keyEquivalent: key.map { $0.key.count == 1 ? $0.key : "" } ?? "")
                if let key, key.key.count == 1 { ask.keyEquivalentModifierMask = key.flags }
                ask.target = self
                ask.representedObject = ImageAct.ask.rawValue
                ask.identifier = NSUserInterfaceItemIdentifier("YabAskAboutImage")
                menu.insertItem(ask, at: last + 1)
            }
        }
    }

    /// A sound file displayed as WebKit's own media document.
    var audioDocument: PointedMedia? {
        guard let media = VideoSave.audioDocument(url, standalone: true) else { return nil }
        let call = NSSelectorFromString("_isDisplayingStandaloneMediaDocument")
        guard responds(to: call) else { return nil }
        typealias Get = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method(for: call), to: Get.self)(self, call) ? media : nil
    }

    /// WebKit's Download Video row, done by Yab: WebKit's own never reaches
    /// the app's downloads, and most videos aren't one file (VideoSave.swift).
    /// A video playing from a blob:, as on x.com, gets none from WebKit:
    /// Yab's own goes where WebKit's would, after the video's own rows.
    func mediaHere(_ menu: NSMenu, since: CFTimeInterval, document: PointedMedia?, again: Bool = true) {
        guard onMedia != nil, !menu.items.contains(where: { ["YabDownloadMedia", "YabDownloadAudio"].contains($0.identifier?.rawValue ?? "") }) else { return }
        if let item = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierDownloadMedia" }) {
            guard again else { return }
            item.target = self
            item.action = #selector(mediaRow(_:))
            // The page receipt can follow WebKit's native menu callback.
            // Until it arrives, only a known direct media document can save.
            let heard = document ?? mediaHeard?(since) ?? url.flatMap {
                VideoSave.isMediaFile($0) ? PointedMedia(src: $0.absoluteString) : nil
            }
            item.title = heard.map(VideoSave.downloadTitle) ?? "Media Download Unavailable"
            item.isEnabled = heard != nil
            if heard == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak item] in
                    guard let self, let item, let heard = self.mediaHeard?(since) else { return }
                    item.title = VideoSave.downloadTitle(heard)
                    item.isEnabled = true
                }
            }
            return
        }
        let videoRows = ["WKMenuItemIdentifierToggleVideoViewer", "WKMenuItemIdentifierToggleEnhancedFullScreen",
                         "WKMenuItemIdentifierToggleFullScreen", "WKMenuItemIdentifierShowHideMediaControls"]
        guard document != nil || menu.items.contains(where: { videoRows.contains($0.identifier?.rawValue ?? "") }) else { return }
        guard let heard = document ?? mediaHeard?(since) else {
            if again {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak menu] in
                    guard let self, let menu else { return }
                    self.mediaHere(menu, since: since, document: self.audioDocument, again: false)
                    Self.dress(menu)
                }
            }
            return
        }
        guard !heard.audio || document != nil else { return }
        let last = menu.items.lastIndex(where: {
            let id = $0.identifier?.rawValue ?? ""
            return videoRows.contains(id) || (document != nil && (id.hasPrefix("WKMenuItemIdentifierMedia")
                || id == "WKMenuItemIdentifierOpenMediaInNewWindow" || id == "WKMenuItemIdentifierCopyMediaLink"))
        })
        let item = NSMenuItem(title: VideoSave.downloadTitle(heard), action: #selector(mediaRow(_:)), keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier(heard.audio ? "YabDownloadAudio" : "YabDownloadMedia")
        guard let last else {
            // A sound in its own tab: WebKit's menu there has no media rows
            // at all, only Reload and the page's own, so the row leads it.
            guard document != nil else { return }
            menu.insertItem(item, at: 0)
            if menu.items.count > 1, !menu.items[1].isSeparatorItem { menu.insertItem(.separator(), at: 1) }
            return
        }
        // Under the separator after the video's rows, where WebKit's sits.
        var at = last + 1
        if at < menu.items.count, menu.items[at].isSeparatorItem { at += 1 } else { menu.insertItem(.separator(), at: at); at += 1 }
        menu.insertItem(item, at: at)
        if at + 1 < menu.items.count, !menu.items[at + 1].isSeparatorItem { menu.insertItem(.separator(), at: at + 1) }
    }

    @objc private func mediaRow(_ item: NSMenuItem) {
        if onMedia?(menuAt) == true { return }
        // Never fall back to WebKit's silent built-in download action.
        // No page receipt and no standalone file is an explicit refusal.
        item.title = "Media Download Unavailable"
        item.isEnabled = false
    }

    /// Copy Text, under Copy Image Address, when the picture holds words:
    /// at once when they were read while the pointer rested on it, else
    /// put in the open menu as soon as they are, and never when there are
    /// none (PictureReader).
    private func wordsHere(_ menu: NSMenu) {
        pictureText = ""
        wordsMenu = menu
        guard let onPictureWords, menu.items.contains(where: { $0.identifier?.rawValue == "YabCopyImageAddress" }) else { return }
        let (now, later) = onPictureWords(menuAt)
        if let now {
            put(now, in: menu)
        } else if let later {
            Task { [weak self, weak menu] in
                guard let words = await later(), let self, let menu, self.wordsMenu === menu else { return }
                self.put(words, in: menu)
            }
        }
    }

    private func put(_ words: PictureWords, in menu: NSMenu) {
        guard !words.isEmpty, !menu.items.contains(where: { $0.identifier?.rawValue == "YabCopyText" }),
              let address = menu.items.firstIndex(where: { $0.identifier?.rawValue == "YabCopyImageAddress" })
        else { return }
        pictureText = words.text
        let item = NSMenuItem(title: "Copy Text", action: #selector(copyPictureText(_:)), keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier("YabCopyText")
        // In the open menu it is dressed on its own, as dress() would have.
        if menu.items.contains(where: { $0.image != nil }) { MenuMark.put(Self.marks["YabCopyText"], on: item) }
        menu.insertItem(item, at: address + 1)
    }

    @objc private func copyPictureText(_ item: NSMenuItem) {
        guard !pictureText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pictureText, forType: .string)
        onPictureCopied?()
    }

    /// The menu let go, or a row of it chosen: input of yours too, for a
    /// window the page opens from it (WindowGate).
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        if wordsMenu === menu { wordsMenu = nil }
        if selectionMenu === menu {
            selectionMenu = nil
            selectionTurn &+= 1
        }
        lastInput = ProcessInfo.processInfo.systemUptime
    }

    @objc private func imageRow(_ item: NSMenuItem) {
        let web = webImage[item.identifier?.rawValue ?? ""]
        guard let act = web?.act ?? (item.representedObject as? String).flatMap(ImageAct.init) else { return }
        // The image action is handled here rather than by the engine, so
        // its Command/Shift intent must travel with it to the Browser too.
        let flags = imageMenuFlags.union(NSApp.currentEvent?.modifierFlags ?? []).union(NSEvent.modifierFlags)
        let foreground = !flags.contains(.command) || flags.contains(.shift)
        if onImage?(act, menuAt, foreground) == true { return }
        if act == .download || act == .capture, onImage != nil {
            // The contextmenu receipt crosses the content-process boundary.
            // A fast pick can beat its delivery while the native menu tracks.
            // Drain one page round trip before falling back to WebKit's row,
            // which does not enter our image-download delegate path.
            let since = menuAt
            callAsyncJavaScript("return null", arguments: [:], in: nil, in: .defaultClient) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.menuAt == since else { return }
                    if self.onImage?(act, since, foreground) == true { return }
                    if let web, let action = web.action { NSApp.sendAction(action, to: web.target, from: item) }
                }
            }
            return
        }
        if let web, let action = web.action {
            NSApp.sendAction(action, to: web.target, from: item)
        }
    }

    /// Hide Element, beside Inspect Element, on a page that can be hidden
    /// from: what was right-clicked goes, as if pointed at in Hide Elements.
    private func hideHere(_ menu: NSMenu, _ event: NSEvent) {
        guard onHideAt != nil, let url, url.scheme == "http" || url.scheme == "https" else { return }
        let at = convert(event.locationInWindow, from: nil)
        let zoom = max(pageZoom * magnification, 0.01)
        hidePoint = CGPoint(x: at.x / zoom, y: (isFlipped ? at.y : bounds.height - at.y) / zoom)
        let item = NSMenuItem(title: "Hide Element", action: #selector(hideElement(_:)), keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier("YabHideElement")
        if let inspect = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierInspectElement" }) {
            menu.insertItem(item, at: inspect)
        } else {
            menu.addItem(.separator())
            menu.addItem(item)
        }
    }

    @objc private func hideElement(_ item: NSMenuItem) { onHideAt?(hidePoint) }

    /// Capture… in the plain page's menu, the one with Reload, with ⇧⌘2's
    /// key beside it: where someone looks who doesn't know the key.
    private func captureHere(_ menu: NSMenu) {
        guard onCapture != nil, let url, url.scheme == "http" || url.scheme == "https",
              menu.items.contains(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierReload" }) else { return }
        let key = Keymap.shared.keys(.capture)
        let item = NSMenuItem(title: "Capture…", action: #selector(captureRow(_:)),
                              keyEquivalent: key.map { $0.key.count == 1 ? $0.key : "" } ?? "")
        if let key, key.key.count == 1 { item.keyEquivalentModifierMask = key.flags }
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier("YabCapturePage")
        let before = ["YabTranslatePage", "YabHideElement", "WKMenuItemIdentifierInspectElement"].lazy
            .compactMap { id in menu.items.firstIndex { $0.identifier?.rawValue == id } }.first
        if let before {
            menu.insertItem(item, at: before)
        } else {
            menu.addItem(.separator())
            menu.addItem(item)
        }
    }

    @objc private func captureRow(_ item: NSMenuItem) { onCapture?() }

    @objc private func inspectElement(_ item: NSMenuItem) {
        // Another context menu may replace webInspect while the card mounts.
        let original = webInspect
        let inspect = { [weak self] in
            guard self != nil, let action = original.action else { return }
            NSApp.sendAction(action, to: original.target, from: item)
        }
        if let onWebInspect { onWebInspect(inspect) }
        else { inspect() }
    }

    @objc private func measureElement(_ item: NSMenuItem) {
        if let measure = onMeasure?() { measure(inspectPoint) }
    }

    @objc private func runSelectionCommand(_ item: NSMenuItem) {
        onSelectionCommand?(item.representedObject as? String)
    }

    @objc private func openAppleCode(_ item: NSMenuItem) {
        onAppleCodeOpen?()
    }

    /// Told where a sideways swipe has got to, and nil when there is none.
    var onPull: ((Pull?) -> Void)?
    /// The title of the tab this one was opened from, while it is open, for
    /// the row past the start of the history.
    var fromTitle: (() -> String?)?
    /// A link-created tab can use Back without WebKit history.
    var canBackToSource: (() -> Bool)?
    /// Let go on that row: that tab, please.
    var onFrom: (() -> Void)?
    /// Back (false) or forward (true) from the mouse's side buttons or
    /// their swipe: the tab's, so they go where the toolbar's Back goes.
    var onStep: ((Bool) -> Void)?
    /// The last of those steps, to tell one press from the same press sent
    /// twice, as a button and as a swipe (Logi Options+ can send both).
    private var stepped: (forward: Bool, swipe: Bool, at: TimeInterval)?
    /// The side button whose press went back or forward, so its let-go
    /// doesn't reach the page as a second press of its own.
    private var stepButton: Int?
    /// Let go on "Search History": the tab's history, for its panel.
    var onHistory: ((TabHistory) -> Void)?
    /// Told the moment the page is reached for, a click, a scroll, so the
    /// picture of a tab waking up never stands between you and the page.
    var onTouch: (() -> Void)?

    /// Set while an agent's own click or keys are being handed to a page, so
    /// they aren't taken for yours.
    static var agentActing = false
    /// A click or a key of yours in a page, for an agent's tab, you taking
    /// the wheel (AgentFeed).
    static var person: ((NSView) -> Void)?
    /// Any click, key or scroll of yours in a page, agent or not: a page
    /// that has stopped answering is asked about (Stuck.swift).
    static var reached: ((PageView) -> Void)?

    /// When you last clicked or pressed a key in the page, by the events'
    /// clock (systemUptime), for a window it asks for a moment after
    /// (WindowGate). Nil once a window has taken it.
    var lastInput: TimeInterval?

    /// A script's window can follow a click with no modifiers in its action.
    /// Only a recent mouse event in this page's window supplies click intent.
    struct WindowClick {
        private var last: (at: TimeInterval, window: Int, button: Int, flags: NSEvent.ModifierFlags)?

        mutating func record(_ event: NSEvent) {
            switch event.type {
            case .leftMouseDown, .leftMouseUp:
                last = (event.timestamp, event.windowNumber, event.buttonNumber, event.modifierFlags)
            case .otherMouseDown where event.buttonNumber == 2, .otherMouseUp where event.buttonNumber == 2:
                last = (event.timestamp, event.windowNumber, event.buttonNumber, event.modifierFlags)
            case .keyDown, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
                last = nil
            default:
                break
            }
        }

        func modifiers(at now: TimeInterval, in window: Int?) -> NSEvent.ModifierFlags? {
            follows(at: now, in: window) ? last?.flags : nil
        }

        func button(at now: TimeInterval, in window: Int?) -> Int? {
            follows(at: now, in: window) ? last?.button : nil
        }

        func follows(at now: TimeInterval, in window: Int?) -> Bool {
            guard let last, let window, window > 0, last.window == window else { return false }
            return now >= last.at && now - last.at <= 0.5
        }
    }

    private var windowClick = WindowClick()

    var hasRecentWindowClick: Bool {
        windowClick.follows(at: ProcessInfo.processInfo.systemUptime, in: window?.windowNumber)
    }

    var recentWindowClickModifiers: NSEvent.ModifierFlags? {
        windowClick.modifiers(at: ProcessInfo.processInfo.systemUptime, in: window?.windowNumber)
    }

    var recentWindowClickButton: Int? {
        windowClick.button(at: ProcessInfo.processInfo.systemUptime, in: window?.windowNumber)
    }

    private func recordWindowInput(_ event: NSEvent) {
        if Self.agentActing { windowClick = WindowClick() } else { windowClick.record(event) }
    }

    override func mouseDown(with event: NSEvent) {
        // A new native down ends a prior capture, including one whose up
        // arrived before its DOM answer. Flush that sequence before this one.
        topPress?.resolve(false)
        topPress = nil
        recordWindowInput(event)
        clearMenuOpen()
        onTouch?()
        // Yours, and so behind what the page asks next (RelayGuard), and
        // what a window it asks for a moment later may follow (WindowGate).
        if !PageView.agentActing { PageView.person?(self); RelayGuard.felt(self); lastInput = event.timestamp }
        PageView.reached?(self)
        // The site's menu at the top: held back, the window's if it moves (TopDrag).
        if TopPress.holds(event, in: self) {
            let press = TopPress(down: event,
                forward: { [weak self] in self?.forwardTopPress($0) },
                drag: { [weak self] in self?.window?.performDrag(with: $0) },
                finished: { [weak self] in self?.topPress = nil })
            topPress = press
            press.check(in: self, zoom: pageZoom)
            return
        }
        super.mouseDown(with: event)
    }

    /// The page says the pointer is on its menu at the top (TopDragRelay).
    var topGrab = false {
        didSet { if !topGrab { topGrabPoint = nil } }
    }
    /// The page point that actually passed the header hit test, in CSS pixels.
    var topGrabPoint: CGPoint?
    private var topPress: TopPress?

    private func forwardTopPress(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: super.mouseDown(with: event)
        case .leftMouseDragged: mouseDragged(with: event)
        case .leftMouseUp: mouseUp(with: event)
        default: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let press = topPress { press.receive(event); return }
        super.mouseDragged(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        recordWindowInput(event)
        clearMenuOpen()
        super.rightMouseDown(with: event)
    }

    /// A Force Click, pressed on past the click, where it was in the view.
    var onForceClick: ((CGPoint) -> Void)?
    /// How firm a press is short of the Force Click, 0 to 1 of the way
    /// there, and 0 again when it lets go (LinkPeek's press dim).
    var onPress: ((CGFloat) -> Void)?
    private var stage = 0

    override func pressureChange(with event: NSEvent) {
        super.pressureChange(with: event)
        defer { stage = event.stage }
        if !PageView.agentActing {
            if event.stage == 1 { onPress?(CGFloat(event.pressure)) } else if event.stage == 0, stage > 0 { onPress?(0) }
        }
        guard event.stage == 2, stage < 2, !PageView.agentActing, let window else { return }
        var point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !isFlipped { point.y = bounds.height - point.y }
        onForceClick?(point)
    }

    override func mouseUp(with event: NSEvent) {
        if let press = topPress { press.receive(event); return }
        recordWindowInput(event)
        super.mouseUp(with: event)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.onSelectionPause?() }
    }

    /// A mouse's side buttons, back and forward, as in every other browser.
    /// No standard numbers them; 3 and 4 is the X11 order most mice and
    /// their drivers send anyway.
    override func otherMouseDown(with event: NSEvent) {
        recordWindowInput(event)
        clearMenuOpen()
        switch event.buttonNumber {
        case 3:
            // Disabled Back is still a browser button. WebKit must not
            // treat it as a click on the link under the pointer.
            stepButton = 3
            if canGoBack || canBackToSource?() == true {
                step(forward: false, swipe: false, at: event.timestamp)
            }
        case 4 where canGoForward:
            stepButton = 4
            step(forward: true, swipe: false, at: event.timestamp)
        default:
            if !PageView.agentActing { lastInput = event.timestamp }
            super.otherMouseDown(with: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        recordWindowInput(event)
        if let button = stepButton, button == event.buttonNumber {
            stepButton = nil
            return
        }
        super.otherMouseUp(with: event)
    }

    /// The same buttons under Logi Options+, which sends them as a swipe
    /// rather than as buttons: deltaX 1 back, -1 forward.
    override func swipe(with event: NSEvent) {
        if event.deltaX > 0 {
            if canGoBack || canBackToSource?() == true { step(forward: false, swipe: true, at: event.timestamp) }
            else if fromTitle?() != nil { onFrom?() }
            else { super.swipe(with: event) }
        } else if event.deltaX < 0, canGoForward {
            step(forward: true, swipe: true, at: event.timestamp)
        } else {
            super.swipe(with: event)
        }
    }

    /// One step, the toolbar's way. A press heard as a button and again as
    /// a swipe a moment later is one press, not two pages back.
    private func step(forward: Bool, swipe: Bool, at time: TimeInterval) {
        if let last = stepped, last.forward == forward, last.swipe != swipe, time - last.at < 0.4 { return }
        stepped = (forward, swipe, time)
        if let onStep { onStep(forward) } else if forward { goForward() } else { goBack() }
    }

    // MARK: - keys the page didn't use (QuietWebView keeps them quiet)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        recordWindowInput(event)
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        recordWindowInput(event)
        clearMenuOpen()
        if !PageView.agentActing { PageView.person?(self); RelayGuard.felt(self); lastInput = event.timestamp }
        PageView.reached?(self)
        super.keyDown(with: event)
    }

    /// Escape the page had no use for ends here. WebKit hands its command,
    /// cancelOperation:, on up the responder chain, and SwiftUI's hosting
    /// view takes it there for its window's Exit Full Screen: every Escape
    /// on a page took the window out of full screen (feedback #167). Safari
    /// and Chrome keep the window as it is; a page's own full screen (a
    /// video's) still ends on Escape, which WebKit handles itself.
    override func cancelOperation(_ sender: Any?) {}

    // MARK: - two fingers sideways

    private var sideways: CGFloat = 0
    private var gatheredX: CGFloat = 0
    private var gatheredY: CGFloat = 0
    private var axis: Swipe.Axis?
    /// Which way the gesture set off, decided once and kept. Turning round
    /// mid-swipe pulls the pill back; it never becomes the other one.
    private var back = true
    /// The page's word on whether this swipe is its own. Nil until it says.
    private var free: Bool?
    private(set) var swipeGesture = 0
    var swipeTrackingEnabled: () -> Bool = { NSEvent.isSwipeTrackingFromScrollEventsEnabled }
    /// Already went somewhere, or was refused: nothing more this gesture.
    private var spent = false
    /// Pages the swipe would go if let go now (`Swipe.steps`).
    private var stepsNow = 0
    /// How far the fingers have gone down (up, less than nought) since the
    /// list came out, each `Swipe.rowPitch` a row.
    private var upDown: CGFloat = 0
    /// Rows moved up and down in the list, changed only a good way past a
    /// row's middle, so a finger resting on a boundary doesn't flicker.
    private var picked = 0
    /// The row the sideways pull had reached when the fingers first went up
    /// or down: from then on, only up and down pick, sideways drift doesn't.
    private var lockedAcross: Int?
    /// Where and when the fingers last moved while the pill was armed: still
    /// there for `Swipe.hold`, they mean the list (feedback #346).
    private var holdAnchor: (time: TimeInterval, travel: CGFloat)?
    private var holdCheck = 0
    /// How far the fingers had come when a hold brought the list out: rows
    /// further are counted from there, not from where the swipe began.
    private var listFrom: CGFloat = 0
    /// Sideways towards no page, on a page with nothing to scroll that way:
    /// the page isn't moved at all, not even to bounce.
    private var nowhere = false
    private var still = false
    /// The pill is on screen: going quick no longer takes it back to a disc.
    private var pillShown = false
    private var retelling = false
    private var lastTap: TimeInterval = 0
    /// The list is out: up and down pick in it.
    private var listing: Bool { axis == .across && free == true && !spent && listedNow }
    private var listedNow = false
    /// Let go while the page's answer was still on its way.
    private var waiting = false
    /// The gesture is over: gone somewhere, refused, or given up on.
    var swipeSettled: Bool { spent && !waiting }
    private var showing = false
    private var going = false
    private var pulls = 0
    /// The history that way, nearest first, read once as the gesture sets
    /// off. Empty is nowhere to go: the pill still comes, faintly, and
    /// never arms, so a swipe on a tab's first page isn't simply dead.
    private var ways: [WKBackForwardListItem] = []
    /// The rows the list shows for them (`Swipe.rows`), read with them.
    private var rows: [Stop] = []
    /// The last few moments of the fingers, for how fast they were going
    /// when they lifted.
    private var trail: [(time: TimeInterval, sideways: CGFloat)] = []
    /// Lifted short of the arm while still going the swipe's way: the
    /// glide macOS sends after the lift carries the swipe on, as it does
    /// Safari's. A Magic Mouse's finger, or a quick flick on a trackpad,
    /// travels a short way and leaves the rest of the swipe to the glide
    /// (feedback #1177, #1268).
    private var coasting = false
    private var coasts = 0

    /// Less than this and there is nothing to show yet, or nothing left to.
    private static let show: CGFloat = 6
    /// A short swipe lifted this fast, in points a second, over at least
    /// `flickReach`, goes one page, however far it got. Only ever one: the
    /// pages behind that are for a hand that means it.
    private static let flick: CGFloat = 1000
    private static let flickReach: CGFloat = 60
    /// Coming back is quicker than going out: every point the fingers give
    /// back counts this many, so thinking better of a deep pull is a short
    /// way home, not the whole way.
    private static let giveBack: CGFloat = 3
    /// How long after the lift the glide has to begin, and how long it may
    /// carry the swipe on, before letting go decides with what there is.
    private static let coastStart: TimeInterval = 0.1
    private static let coastLongest: TimeInterval = 0.6

    // MARK: - two fingers together

    // Both gestures of two fingers together are WebKit's own.
    // The pinch scales the rendered layers on the GPU around the fingers
    // and lays the page out again only once they lift. Smart Zoom, two
    // fingers tapped twice, asks the page for the block under them and
    // animates its scale and scroll there in one Core Animation move (about
    // a quarter of a second), and back out on the next tap. Doing either
    // from here was measured worse: a real change of scale on every pinch
    // event ran at a few frames a second, and a smart zoom made of
    // JavaScript, `setMagnification(_:centeredAt:)` and a scroll jumped in
    // one frame, 80 ms late, with no motion at all (evals/smart-zoom).

    /// With YAB_SWIPE_LOG set to a path, every event of a swipe and what
    /// was made of it, one line each, for finding out why one felt wrong.
    private static let swipeLog: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["YAB_SWIPE_LOG"], !path.isEmpty else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    private func note(_ line: @autoclosure () -> String) {
        guard let log = PageView.swipeLog else { return }
        let time = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        log.write(Data("\(time) \(line())\n".utf8))
    }

    private var swipeState: String {
        let a = axis.map { $0 == .across ? "across" : "down" } ?? "-"
        let f = free.map { $0 ? "free" : "taken" } ?? "?"
        return "axis=\(a) page=\(f) spent=\(spent) sideways=\(Int(sideways)) travel=\(Int(travel)) upDown=\(Int(upDown)) steps=\(stepsNow)/\(rows.count) list=\(listing)"
    }

    /// A mouse wheel's notches, each sent on to WebKit a frame at a time.
    private(set) lazy var glide = WheelGlide(view: self) { [weak self] event in self?.glideOn(event) }

    private func glideOn(_ event: NSEvent) { super.scrollWheel(with: event) }

    override func scrollWheel(with event: NSEvent) {
        LinkStatus.shared.scrolled()
        let gesture = Swipe.isGesture(event)
        // A trackpad's gesture that begins here stays here (ScrollLatch).
        if gesture, event.phase == .began || event.phase == .mayBegin { ScrollLatch.hold(self) }
        WheelLatch.hold(self, event)
        if event.phase == .began || (event.phase == [] && event.momentumPhase == []) { PageView.reached?(self) }
        onTouch?()
        // A wheel is independent of the last swipe, even while it settles.
        // Notches still glide; a smooth mouse's own points go on as they are.
        guard gesture else {
            if !glide.take(event) { super.scrollWheel(with: event) }
            return
        }
        let navigationEnabled = swipeTrackingEnabled()
        if coasting, event.phase == [], event.momentumPhase != [] {
            super.scrollWheel(with: event)
            if navigationEnabled { coast(event) } else { cancelSwipe() }
            return
        }
        guard Swipe.isNavigationGesture(event, enabled: navigationEnabled) else {
            if !navigationEnabled { cancelSwipe() }
            super.scrollWheel(with: event)
            return
        }
        if PageView.swipeLog != nil, event.phase != [] || event.momentumPhase != [] {
            note("event phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue) dx=\(String(format: "%.1f", event.scrollingDeltaX)) dy=\(String(format: "%.1f", event.scrollingDeltaY)) inverted=\(event.isDirectionInvertedFromDevice) precise=\(event.hasPreciseScrollingDeltas) | \(swipeState)")
        }
        // The page gets every event and scrolls as it always did. The
        // swipe is only read, never taken, but for one moment: while the
        // list of pages is out, the fingers going up and down pick in it,
        // and the page under it keeps still.
        if event.phase == .mayBegin || event.phase == .began {
            // Fingers down again stop the glide, and with it the last swipe.
            if coasting {
                coasting = false
                coasts += 1
                spent = true
                settle(nil)
            }
            swipeGesture += 1
            if Swipe.listensEarly, !LinkGap.cut("swipe") { evaluateInYab("window.__yabSwipe && window.__yabSwipe.begin(\(swipeGesture))") }
            nowhere = false
            still = false
        }
        let deciding = axis == nil
        if deciding, !spent, event.phase == .changed, event.momentumPhase == [] {
            gatheredX += abs(event.scrollingDeltaX)
            gatheredY += abs(event.scrollingDeltaY)
            sideways += event.scrollingDeltaX
            axis = Swipe.axis(x: gatheredX, y: gatheredY)
            // Only a sideways gesture asks the page to listen: any wheel
            // listener makes WebKit wait for the page's main thread before
            // scrolling, which stalled busy vertical feeds (#175).
            // Begin before WebKit gets the first sideways wheel. Beginning
            // afterwards can miss it, leaving a short swipe unqualified
            // and only the page's edge bounce.
            if axis == .across, !Swipe.listensEarly, !LinkGap.cut("swipe") {
                evaluateInYab("window.__yabSwipe && window.__yabSwipe.begin(\(swipeGesture))")
            }
        }
        // Nor while the swipe goes towards no page and the page has nothing
        // of its own to scroll that way: it stays put rather than sliding
        // and springing back. Its end still goes, to settle anything begun.
        let listingNow = event.phase == .changed && event.momentumPhase == [] && listing
        let stillNow = still && (event.phase == .changed || event.momentumPhase != [])
        // A mouse wheel's notch glides (WheelGlide).
        if !(listingNow || stillNow), !glide.take(event) {
            super.scrollWheel(with: event)
        }
        // Only a live trackpad gesture, not its glide afterwards, and not a
        // mouse wheel, which has no beginning or end to speak of.
        guard event.momentumPhase == [] else { return }

        switch event.phase {
        case .mayBegin, .began:
            sideways = 0
            gatheredX = 0
            gatheredY = 0
            axis = nil
            free = nil
            spent = false
            stepsNow = 0
            listedNow = false
            upDown = 0
            picked = 0
            lockedAcross = nil
            pillShown = false
            holdAnchor = nil
            holdCheck += 1
            listFrom = 0
            waiting = false
            showing = false
            ways = []
            rows = []
            trail = []
            // A pill still on its way out belongs to the last gesture. It
            // is already invisible; it is only taken off the stage so the
            // next one arrives fresh rather than fading back in.
            pulls += 1
            if going {
                going = false
                onPull?(nil)
            }
        case .changed:
            guard !spent else { return }
            guard let axis else { return }
            if deciding {
                note("decided \(axis == .across ? "across" : "down") gathered x=\(Int(gatheredX)) y=\(Int(gatheredY))")
                if axis == .down {
                    spent = true
                    return
                }
                // Pinched in, the fingers are moving around inside what was
                // magnified, the page itself may be no wider than the window.
                // Reaching its edge there is not a wish to leave.
                if magnification > 1.01 {
                    note("magnified \(String(format: "%.2f", magnification)), left to pan")
                    spent = true
                    return
                }
                back = sideways > 0
                (rows, ways) = stops(back: back)
                if PageView.swipeLog != nil {
                    let list = backForwardList
                    note("\(back ? "back" : "forward"): back \(list.backList.count) \(list.backList.map { PageView.named($0).title }) | now \(list.currentItem.map { PageView.named($0).title } ?? "-") | forward \(list.forwardList.count) \(list.forwardList.map { PageView.named($0).title }) | rows \(rows.map(\.title))")
                }
                // Nowhere to go that way: nothing to pull out.
                if rows.isEmpty {
                    note("nothing that way")
                    spent = true
                    nowhere = true
                    if free == true { still = true }
                    note("nothing that way, page \(still ? "kept still" : "left to scroll")")
                    return
                }
                note(event)
                tell()
                return
            }
            let dx = event.scrollingDeltaX
            if back ? dx < 0 : dx > 0 {
                sideways = back ? max(0, sideways + dx * PageView.giveBack) : min(0, sideways + dx * PageView.giveBack)
            } else {
                sideways += dx
            }
            // Down the list as the fingers go down, whichever way the Mac
            // is set to scroll.
            let down = event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY
            if listing {
                upDown += down
            }
            note(event)
            tell()
        case .ended:
            lifted()
        case .cancelled:
            cancelSwipe()
        default:
            break
        }
    }

    private func note(_ event: NSEvent) {
        trail.append((event.timestamp, sideways))
        if trail.count > 6 { trail.removeFirst(trail.count - 6) }
    }

    /// The fingers' speed now: nought once they have sent nothing for
    /// `Swipe.quickRest`, which is what fingers at rest do.
    private func live(_ now: TimeInterval) -> CGFloat {
        guard let last = trail.last, now - last.time < Swipe.quickRest else { return 0 }
        return speed
    }

    /// Points a second the fingers were going, the way the swipe set off,
    /// over the last events before they lifted.
    private var speed: CGFloat {
        guard let first = trail.first, let last = trail.last, last.time - first.time > 0.005 else { return 0 }
        let moved = (last.sideways - first.sideways) * (back ? 1 : -1)
        return moved / CGFloat(last.time - first.time)
    }

    /// The fingers lifted. Short of the arm but still going the swipe's way,
    /// the glide after the lift decides; otherwise letting go does, now.
    private func lifted() {
        let flicked = travel >= PageView.flickReach && speed >= PageView.flick
        guard !spent, free != false, axis == .across, !rows.isEmpty, stepsNow == 0, !listedNow,
              !flicked, speed >= 0 else {
            release()
            return
        }
        coasting = true
        gliding = false
        coasts += 1
        let mine = coasts
        note("coast from travel \(Int(travel)) speed=\(Int(speed)) | \(swipeState)")
        // No glide at all: the fingers had stopped, or the Mac sends none.
        DispatchQueue.main.asyncAfter(deadline: .now() + PageView.coastStart) { [weak self] in
            guard let self, coasting, coasts == mine, !gliding else { return }
            endCoast()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + PageView.coastLongest) { [weak self] in
            guard let self, coasting, coasts == mine else { return }
            endCoast()
        }
    }

    private var gliding = false

    /// A glide event after the lift: its travel counts as the fingers'
    /// did, and the swipe goes as soon as it reaches the arm.
    private func coast(_ event: NSEvent) {
        switch event.momentumPhase {
        case .began, .changed:
            gliding = true
            sideways += event.scrollingDeltaX
            note("coast dx=\(String(format: "%.1f", event.scrollingDeltaX)) | \(swipeState)")
            guard !spent else { return endCoast() }
            tell()
            if stepsNow > 0 { endCoast() }
        case .ended, .cancelled:
            endCoast()
        default:
            break
        }
    }

    private func endCoast() {
        guard coasting else { return }
        coasting = false
        gliding = false
        coasts += 1
        release()
    }

    /// Invalidate replies from an old gesture or a document being replaced.
    func cancelSwipe() {
        coasting = false
        gliding = false
        coasts += 1
        swipeGesture += 1
        spent = true
        waiting = false
        nowhere = false
        still = false
        settle(nil)
    }

    /// Only replies from this gesture in the main document may authorize it.
    func answer(free yes: Bool, gesture: Int, finished: Bool = false) {
        guard gesture == swipeGesture else { return }
        note("page says \(yes ? "free" : "taken") | \(swipeState)")
        if nowhere { still = yes }
        guard axis != .down, !spent else { return }
        guard yes else {
            free = false
            waiting = false
            spent = true
            settle(nil)
            return
        }
        free = true
        tell()
        if waiting && finished {
            waiting = false
            release(confirmed: true)
        }
    }

    /// Only the distance in the direction it set off in. Past the origin the
    /// other way is just nought.
    private var travel: CGFloat { max(0, back ? sideways : -sideways) }

    private func tell() {
        guard free == true else { return }

        let travel = travel
        // Drawn all the way back, the pill goes; drawn out again, it
        // returns. Nothing is decided until the fingers lift.
        guard travel >= PageView.show else {
            // Back home, however quick: a flick back can come all the way
            // in one event, past the arm with no step in between, and what
            // was armed must not still be when the fingers lift.
            if stepsNow != 0 || listedNow { note("home from steps \(stepsNow) list \(listedNow)") }
            stepsNow = 0
            listedNow = false
            pillShown = false
            holdAnchor = nil
            upDown = 0
            picked = 0
            lockedAcross = nil
            if showing { settle(nil) }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let armedHere = Swipe.steps(travel: travel, rows: rows.count) > 0
        // However far or slow the pull, letting go goes one page. The list
        // of pages behind comes out only for fingers held still a moment
        // with the pill armed (feedback #346): a long swipe that went past
        // where the list used to open went to the history instead of back.
        if !armedHere || listedNow || rows.count < 2 {
            holdAnchor = nil
        } else if let anchor = holdAnchor, abs(travel - anchor.travel) <= Swipe.holdSlop {
            // Resting, or near enough: the clock runs on.
        } else {
            holdAnchor = (now, travel)
            awaitHold()
        }
        let held = holdAnchor.map { now - $0.time >= Swipe.hold - 0.005 } ?? false
        var listed = listedNow ? armedHere : held
        if listed, !listedNow {
            listFrom = travel
            note("list out after a hold at travel \(Int(travel))")
        }
        if !listed { listFrom = 0 }
        // Rows past the first, while the list is out, by how much further
        // the fingers pull from where it came out.
        let across = listed ? Swipe.steps(travel: Swipe.open + max(0, travel - listFrom), rows: rows.count)
                            : Swipe.steps(travel: travel, rows: rows.count)
        if rows.count < 2 { listed = false }
        // Going quick, either way: the fingers are on their way somewhere,
        // so nothing new grows under them, no pill out of the disc, only to
        // be taken back a frame later. What shows stays; the rest comes once
        // they slow or rest a moment.
        let quick = abs(live(now)) >= Swipe.passSpeed
        // Pulled back to where there is no list, what the fingers did up and
        // down is let go of with it.
        var steps = across
        if listed {
            let pitch = Swipe.rowPitch
            if lockedAcross == nil, abs(upDown) >= pitch / 2 { lockedAcross = across }
            let base = lockedAcross ?? across
            // Nothing banked past either end: turning back moves at once.
            // Above the first row is a row's worth of nothing: let go there
            // and the page stays.
            upDown = min(max(upDown, (CGFloat(-base) - 0.5) * pitch), (CGFloat(rows.count - base) + 0.5) * pitch)
            let at = upDown / pitch
            while at > CGFloat(picked) + 0.6 { picked += 1 }
            while at < CGFloat(picked) - 0.6 { picked -= 1 }
            steps = min(max(lockedAcross == nil ? 1 : 0, base + picked), rows.count)
        } else {
            upDown = 0
            picked = 0
            lockedAcross = nil
            // The list held back: the pill's page, however far out.
            steps = min(steps, 1)
        }
        let passing = quick && steps > 0 && !pillShown && !listed
        if steps == 0 { pillShown = false } else if !passing { pillShown = true }
        if quick, !retelling {
            // Fingers that stop send nothing more: a look again in a moment
            // shows what they rest on. One look at a time; still quick then,
            // it sets the next.
            retelling = true
            let gesture = pulls
            DispatchQueue.main.asyncAfter(deadline: .now() + Swipe.quickRest + 0.01) { [weak self] in
                guard let self else { return }
                retelling = false
                guard pulls == gesture, !spent, showing else { return }
                tell()
            }
        }
        if steps != stepsNow || listed != listedNow {
            note("steps \(stepsNow) -> \(steps) across=\(across) locked=\(lockedAcross.map(String.init) ?? "-") picked=\(picked) list \(listedNow) -> \(listed) passing=\(passing)")
        }
        // A firmer tap for every page further, a lighter one for every page
        // given back, so you know without looking how deep letting go would
        // take you, and that at nought it is safe. The list coming out or
        // folding is a tap of its own; two within a moment are one.
        let opens = listed != listedNow
        if steps != stepsNow || opens {
            let firmer = steps > stepsNow || (steps == stepsNow && listed)
            if now - lastTap > 0.06 {
                NSHapticFeedbackManager.defaultPerformer.perform(firmer ? .levelChange : .alignment, performanceTime: .now)
                lastTap = now
            }
        }
        listedNow = listed
        stepsNow = steps
        var pull = pull(travel: travel, steps: steps, going: false)
        pull.passing = passing
        pull.quick = quick
        settle(pull)
    }

    /// A look once the fingers have been still for `Swipe.hold`: resting
    /// fingers send nothing, so nothing else would bring the list out.
    private func awaitHold() {
        holdCheck += 1
        let mine = holdCheck
        DispatchQueue.main.asyncAfter(deadline: .now() + Swipe.hold) { [weak self] in
            guard let self, holdCheck == mine, !spent, !waiting, free == true, holdAnchor != nil else { return }
            tell()
        }
    }

    private func pull(travel: CGFloat, steps: Int, going: Bool) -> Pull {
        Pull(back: back, travel: travel, steps: steps, stops: rows, blocked: rows.isEmpty, listed: listedNow, going: going)
    }

    /// A history entry as a row names it: its title, or failing that its
    /// site, or its address.
    static func named(_ item: WKBackForwardListItem) -> (title: String, host: String) {
        let host = item.url.host() ?? ""
        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (title.isEmpty ? (host.isEmpty ? item.url.absoluteString : host) : title, host)
    }

    private func release(confirmed: Bool = false) {
        guard swipeTrackingEnabled() else { cancelSwipe(); return }
        // Even an earlier free reply must be checked after the last wheel:
        // the page may have consumed a later event in the same gesture.
        if !confirmed, !spent, axis == .across, !rows.isEmpty {
            guard !waiting else { return }
            waiting = true
            let mine = swipeGesture
            evaluateInYab("window.__yabSwipe && window.__yabSwipe.finish(\(mine))")
            // This includes IPC and the page's wheel handlers, not just our
            // 32 ms coalescing timer. A busy article must get time to reply.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                guard let self, waiting, swipeGesture == mine else { return }
                // Silence is not permission to leave a busy page.
                cancelSwipe()
            }
            return
        }
        defer { spent = true }
        guard !spent, free == true, !rows.isEmpty else {
            note("let go: nothing (spent or page's or no rows) | \(swipeState)")
            settle(nil)
            return
        }
        var steps = stepsNow
        if steps == 0, !listedNow, travel >= PageView.flickReach, speed >= PageView.flick { steps = 1 }
        guard steps > 0, steps <= rows.count else {
            note("let go short: nothing, speed=\(Int(speed)) | \(swipeState)")
            settle(nil)
            return
        }
        let stop = rows[steps - 1]
        note("let go on row \(steps) \(stop.kind) \"\(stop.title)\" speed=\(Int(speed)) | \(swipeState)")
        going = true
        settle(pull(travel: travel, steps: steps, going: true))
        take(stop, back: back, pages: ways)
        pulls += 1
        let mine = pulls
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self, pulls == mine else { return }
            going = false
            settle(nil)
        }
    }

    /// The rows that way, nearest first, and the history they stand for,
    /// read now: for a swipe as it sets off, and for the list a held back
    /// or forward door shows (DoorList), the same rows either way.
    func stops(back: Bool) -> (stops: [Stop], pages: [WKBackForwardListItem]) {
        let pages: [WKBackForwardListItem] = back ? backForwardList.backList.reversed() : backForwardList.forwardList
        return (Swipe.rows(pages.map(PageView.named), from: back ? fromTitle?() : nil), pages)
    }

    /// The page a row stands for, to open it in a tab of its own.
    func address(of stop: Stop, pages: [WKBackForwardListItem]) -> URL? {
        guard stop.kind == .page || stop.kind == .run, stop.index < pages.count else { return nil }
        return pages[stop.index].url
    }

    /// Where a row goes, with the history it was read with (`stops`).
    func take(_ stop: Stop, back: Bool, pages: [WKBackForwardListItem]) {
        switch stop.kind {
        case .page, .run:
            if stop.index == 0 {
                if back { goBack() } else { goForward() }
            } else if stop.index < pages.count {
                go(to: pages[stop.index])
            }
        case .from:
            onFrom?()
        case .search:
            onHistory?(history())
        }
    }

    private func settle(_ pull: Pull?) {
        showing = pull != nil
        onPull?(pull)
    }

    /// The tab's whole history for its panel, the newest first, the page
    /// you are on marked, and what a pick of each does.
    func history() -> TabHistory {
        let list = backForwardList
        let items = list.forwardList.reversed() + (list.currentItem.map { [$0] } ?? []) + list.backList.reversed()
        let entries = items.enumerated().map { index, item in
            let (title, host) = PageView.named(item)
            return TabHistory.Entry(id: index, title: title, host: host, url: item.url, current: item == list.currentItem)
        }
        return TabHistory(entries: entries) { [weak self] index in
            guard let self, index < items.count, items[index] != backForwardList.currentItem else { return }
            go(to: items[index])
        }
    }

}

/// WebKit already adds a page's attached controller before willOpenMenu.
/// A fallback is only for a different owner or a page without that controller;
/// titles and item identifiers cannot identify an extension action safely.
enum PageExtensionMenus {
    @MainActor static func append(to menu: NSMenu, nativeController: AnyObject?, owner: AnyObject,
                                  fallback: () -> [NSMenuItem]) {
        guard nativeController !== owner else { return }
        let items = fallback()
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        items.forEach(menu.addItem)
    }
}

/// The selected words, never a link underneath them or a search query.
enum SelectedURLMenu {
    struct Destination {
        let url: URL
        let source: URL?
    }

    static func url(_ words: String) -> URL? {
        // One line of words: a paragraph taken whole brings its line break,
        // two lines are two things.
        let lines = words.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count == 1 else { return nil }
        let text = unwrapped(lines[0])
        // Reject paths before Address's file handling (including ~ expansion).
        guard !text.isEmpty, !text.hasPrefix("/"), !text.hasPrefix("~"),
              !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = Address.url(from: text, names: false),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// An address as a sentence holds it: the full stop or comma after
    /// it, the brackets or quotes round it, left off. A closing bracket
    /// the address opened itself stays (wiki/Mercury_(planet)).
    static func unwrapped(_ text: String) -> String {
        let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "<": ">", "\"": "\"", "'": "'",
                                             "“": "”", "‘": "’", "«": "»", "`": "`"]
        var text = Substring(text)
        while true {
            let before = text
            text = text.drop { $0.isWhitespace }
            while let last = text.last, last.isWhitespace || ".,;:!?…".contains(last) { text = text.dropLast() }
            if let first = text.first, let close = pairs[first] {
                let inner = text.dropFirst().dropLast()
                let balanced = first == close || inner.filter { $0 == first }.count == inner.filter { $0 == close }.count
                text = text.count > 1 && text.last == close && balanced ? inner : text.dropFirst()
            } else if let last = text.last, let open = pairs.first(where: { $0.value == last && $0.key != last })?.key,
                      text.filter({ $0 == open }).count < text.filter({ $0 == last }).count {
                text = text.dropLast()
            } else if let last = text.last, "\"'`".contains(last), text.filter({ $0 == last }).count % 2 == 1 {
                text = text.dropLast()
            }
            if text == before { return String(text) }
        }
    }

    /// The selected words and the address of the link they are in, or
    /// null when the selection is not inside one link.
    static let selectedInLink = """
    (function() {
      var s = getSelection();
      if (!s || !s.rangeCount || s.isCollapsed) return null;
      var c = s.getRangeAt(0).commonAncestorContainer;
      var el = c.nodeType === 1 ? c : c.parentElement, a = el && el.closest('a[href]');
      return a ? [String(s), a.href] : null;
    })()
    """

    /// Not offered where the link pointed at already goes there (Open Link).
    static func url(_ words: String, besides link: String) -> URL? {
        guard let url = url(words) else { return nil }
        let bare = { (u: URL) in u.absoluteString.hasSuffix("/") ? String(u.absoluteString.dropLast()) : u.absoluteString }
        if let link = URL(string: link), bare(link) == bare(url) { return nil }
        return url
    }

    @MainActor static func insert(_ words: String, source: URL?, into menu: NSMenu,
                                  target: AnyObject, action: Selector) -> NSMenuItem? {
        guard let url = url(words),
              !menu.items.contains(where: { $0.identifier?.rawValue == "YabGoToSelectedURL" }),
              let at = place(in: menu)
        else { return nil }
        let item = NSMenuItem(title: "Go to “\(Address.pretty(url))”", action: action, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("YabGoToSelectedURL")
        item.target = target
        item.representedObject = Destination(url: url, source: source)
        menu.insertItem(item, at: at)
        return item
    }

    /// Above Search with…, or, in a link's menu, under the link's rows.
    private static func place(in menu: NSMenu) -> Int? {
        if let search = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierSearchWeb" }) {
            return search
        }
        return menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyLink" }).map { $0 + 1 }
    }
}

extension Browser {
    /// WebKit holds a page's right-click menu back for this before showing
    /// it (WKUIDelegatePrivate): the page's selection is read then, so rows
    /// made from it are in the menu as it opens (PageView.readBeforeMenu).
    @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
    func contextMenu(_ webView: WKWebView, proposed menu: NSMenu, element: AnyObject?, userInfo: AnyObject?,
                     completionHandler: @escaping (NSMenu?) -> Void) {
        guard let page = webView as? PageView else { completionHandler(menu); return }
        // An older menu's read, overtaken by a newer right-click, still
        // answers WebKit: with no menu, which WebKit then doesn't show
        // (WebContextMenuProxyMac::showContextMenuWithItems).
        page.readBeforeMenu(menu) { current in completionHandler(current ? menu : nil) }
    }
}

extension NSView {
    /// A view about to be taken out of any window with the keys, it or a
    /// view inside it, gives them up first, so its own resignFirstResponder
    /// runs. Not on the way to another window (full screen, a tab torn
    /// off), whose own code hands the keys over.
    /// AppKit takes them from a view taken out of its window without asking
    /// it, and WebKit only lets Secure Event Input go in its resign: a
    /// page switched away from with a password field focused left it on,
    /// and while it is on macOS keeps Caps Lock from switching input
    /// sources, in Yab and every other app (feedback #949, #1563).
    func giveUpKeys(leavingFor newWindow: NSWindow?) {
        guard newWindow == nil, let window, let responder = window.firstResponder as? NSView,
              responder === self || responder.isDescendant(of: self) else { return }
        window.makeFirstResponder(nil)
    }
}
