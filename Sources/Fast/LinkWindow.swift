import Carbon.HIToolbox
import SwiftUI
import WebKit

// A link from another app, in a small window of its own, the way Arc has
// Little Arc: a click in Mail or Slack is most often a look, not a move, so
// the page comes up over the app you were in, to read and close with ⌘W,
// and only goes into the tabs if you say so, with ⌘O or Open, or by asking
// for full screen, its green light or ⌃⌘F.
//
// The page is a tab like any other, signed in wherever you are, with its
// passwords and extensions, only not yet in the row (Browser.outside).
// Keeping it moves that very page into the row, loaded as it is and nothing
// loaded twice, in one frame, as Little Arc hands its page over.
//
// Its page in Settings is Small Window. Links from other apps come to it
// unless that is turned off, when they open in a tab as they always did;
// and ⌥⌘N brings up an empty one from any app, as Little Arc's key does,
// unless that is turned off too. A link on a
// page is looked at with ⇧-click instead, over the page (LinkPeek.swift).

@MainActor
final class LinkWindow: NSObject, NSWindowDelegate {
    /// A class of its own, for WindowDrag to teach without reaching every
    /// other window in the app.
    ///
    /// Full screen, by the green light, its menu, the View menu or ⌃⌘F,
    /// is a wish for the whole browser, not a small window filling the
    /// screen: the page goes into the main window's tabs, in the space on
    /// screen, and that window comes forward, as Little Arc's green light
    /// opens its page in Arc (register #1099).
    final class Frame: NSWindow {
        override func toggleFullScreen(_ sender: Any?) {
            guard !styleMask.contains(.fullScreen), let link = LinkWindow.owning(self) else {
                return super.toggleFullScreen(sender)
            }
            link.keep()
        }
    }

    /// Takes keys over another app's full-screen window without activating
    /// the browser and bringing its desktop Space forward.
    final class FullScreenFrame: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }

        override func toggleFullScreen(_ sender: Any?) {
            guard let link = LinkWindow.owning(self) else { return }
            link.keep()
        }
    }

    /// ⌃⌘F, full screen in every Mac app, by where the key sits, as the
    /// browser's window hears it (ContentView.take).
    nonisolated static func fullScreenKey(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        code == UInt16(kVK_ANSI_F) && flags.intersection([.command, .option, .control, .shift]) == [.control, .command]
    }

    /// Whether a link from another app comes up in one.
    nonisolated static var wanted: Bool { Store.settings.object(forKey: key) as? Bool ?? true }
    nonisolated static let key = "links.small"
    /// Whether its key, ⌥⌘N or the one given it in Shortcuts, opens one
    /// from any app: on unless turned off, as Little Arc's is.
    nonisolated static func keyWanted(in store: UserDefaults = Store.settings) -> Bool {
        store.object(forKey: hotkeyKey) as? Bool ?? true
    }
    nonisolated static let hotkeyKey = "links.small.key"

    /// Only ordinary windows remember a user's adjustment. Page-sized
    /// sign-in popups and automatic placement never replace this choice.
    nonisolated static let frameKey = "links.small.frame"
    private let remembersFrame: Bool
    private var moving = false
    private var moveEnd: DispatchWorkItem?

    /// Open ones, oldest first, each until it is closed or kept.
    private static var open: [LinkWindow] = []
    static var all: [LinkWindow] { open }

    let tab: Tab
    private(set) weak var browser: Browser?
    /// This window as extensions know it (Extensions.follow).
    let extensionKey = UUID()
    let window: NSWindow
    /// Where the page lies, the card under the bar.
    private let holder: PageHolder
    /// What the bar shows beyond the page: the field being typed in, and
    /// a copy just made.
    private let bar = LinkBarState()
    /// A probe's pointer over the field (Bench `fieldhover`).
    func point(_ on: Bool) { bar.pointed = on }
    /// Its corner saying a copy (Bench `links`).
    var noticeShown: Bool { bar.toaster.shown }
    /// Back, forward and reload for this page, from the bar's doors and
    /// this window's keys alike, counted here so they kick these doors.
    let steer = HelmSteer()
    /// Handed to the row: closing the window no longer closes the page.
    private var kept = false
    /// Snapshot callbacks may arrive after a direct handoff has already won.
    private var handed = false
    /// The space picked from the button's list to keep it into, when not
    /// the one on screen.
    private var into: UUID?
    /// The space a route sent its link to (LinkRoutes.swift): Open names
    /// it and keeps the page there. Nil for the one on screen.
    private let home: UUID?
    /// Downloads keep the Space this window came from even if the main
    /// window switches away; this does not change where Open puts its tab.
    let downloadSpace: UUID
    /// Kept as its address in a space with sign-ins of its own: the page
    /// here is let go as the window closes, the row has another.
    private var carried = false
    /// The hosting view, for the list of spaces to hang from.
    private weak var room: NSView?
    /// The app that was in front when it came up, Spotify with its sign-in,
    /// gone back to when it closes: a look from there is over, and the
    /// browser was never asked for. Nil when it came from yab itself.
    private let cameFrom: NSRunningApplication?

    /// A question of yab's up over this window (QuestionStand).
    private(set) var asking = false

    /// The one a key was pressed in, if it was one.
    static func owning(_ window: NSWindow?) -> LinkWindow? {
        guard let window else { return nil }
        return open.first { $0.window === window }
    }

    /// The one showing this page, if one is.
    static func owning(page: NSView) -> LinkWindow? {
        open.first { $0.tab.builtPage === page }
    }

    /// The one in front: key, or under the key popover hung from it.
    static var inFront: LinkWindow? { inFront(key: NSApp.keyWindow) }

    /// A kept one isn't, though it may stay key until the stage has its page.
    static func inFront(key: NSWindow?) -> LinkWindow? {
        var window = key
        while let current = window {
            if let link = owning(current) { return link.kept ? nil : link }
            window = current.parent
        }
        return nil
    }

    /// Its keys, heard by the app for any window of its, before the menus
    /// give ⌘W to the browser's tab. Its own and not the browser window's:
    /// a link that launched the app has no browser window to listen for it.
    private static var keys: Any?
    private static func listen() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let link = owning(event.window) else { return event }
            return link.take(event) ? nil : event
        }
    }

    /// ⌥⌘N, or the key given it in Shortcuts, for the whole Mac.
    static let globalKey: GlobalKey = GlobalKey(id: 1, pressed: { LinkWindow.blank() },
                                                again: { LinkWindow.hotkey(LinkWindow.globalKey.state != .off) })

    nonisolated static func plan(on: Bool, keys: Hotkey?, code: (String) -> UInt16?) -> (keys: Hotkey, code: UInt16)? {
        GlobalKey.plan(on: on, keys: keys, code: code)
    }

    static func hotkey(_ on: Bool) {
        globalKey.register(on: on, keys: Keymap.shared.keys(.newSmallWindow))
    }

    /// An empty small window, its field ready to be typed in: a look at
    /// something, from wherever you are, without the browser coming up.
    static func blank() {
        guard let browser = Links.browser else { return }
        let tab = browser.blankTab()
        browser.prepare(tab)
        browser.outside.append(tab)
        present(tab, for: browser)
        guard let link = open.last, link.tab === tab, !link.kept else { return }
        // Once the field is on screen: set before, it would never be focused.
        DispatchQueue.main.async { link.raise() }
    }

    /// A link from another app, in a new small window in front of it;
    /// with a `home`, the space its route keeps it, in that space's store,
    /// signed in as that space is.
    static func show(_ url: URL, for browser: Browser, home: UUID? = nil) {
        let tab = home.map { Tab(configuration: Web.configuration(store: Spaces.store(for: $0))) } ?? browser.blankTab()
        browser.prepare(tab)
        browser.outside.append(tab)
        tab.go(to: url)
        present(tab, for: browser, home: home)
    }

    /// A page already made and already outside the row, a sign-in window
    /// a small window's page opened, say, in a small window of its own,
    /// at the size the page asked for if it asked.
    static func present(_ tab: Tab, for browser: Browser, size: NSSize? = nil, home: UUID? = nil) {
        listen()
        let remembersFrame = size == nil && tab.opener == nil && tab.scripted == nil && !tab.popup
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        let spare = free(preferred: remembersFrame ? savedFrame() : nil, screens: screens, mouse: mouse)
        // Every screen taken by an app in full screen: the window comes up
        // over that app in its own Space, as Little Arc's does (register 533).
        let pointer = underPointer(screens: screens, mouse: mouse)
        let screen = spare ?? pointer
        let admission = fullscreenAdmission(
            legacyScreenIndex: screen.flatMap { selected in screens.firstIndex { $0 === selected } },
            legacyOver: spare == nil,
            pointerScreenIndex: pointer.flatMap { selected in screens.firstIndex { $0 === selected } },
            own: ownFullscreen(in: screens))
        // The decision changes only the panel kind, never the legacy target.
        let over = admission.over
        let frame = screen.map { place(size, on: $0, remembering: remembersFrame) }
        let link = LinkWindow(tab: tab, browser: browser, from: origin(), home: home, size: frame?.size,
                              remembersFrame: remembersFrame, over: over)
        open.append(link)
        guard let frame else { return link.settle() }
        if #available(macOS 15.4, *) { Extensions.all.forEach { $0.follow(link) } }
        if over { link.joinFullScreenSpace() }
        link.appear(at: frame)
    }

    /// The app in front as one comes up. A link clicked in Spotify has
    /// yab brought forward before the link reaches it, so yab in front a
    /// moment ago means the app before it; longer ago, yab was in front
    /// already: another small window whose page opened this one, a sign-in
    /// window, which goes back where that one would, or the browser.
    private static func origin() -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        if front != .current { return front }
        if let link = owning(NSApp.keyWindow) { return link.cameFrom }
        return CACurrentMediaTime() - cameForward < 1 ? before : nil
    }

    /// The last other app in front, and when yab last came forward, from
    /// the launch on: a link that launches yab finds the app it came from
    /// in front as the browser is made.
    private static var before: NSRunningApplication?
    private static var cameForward: CFTimeInterval = 0
    private static var watching: Any?
    static func watch() {
        guard watching == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front != .current {
            before = front
        }
        cameForward = CACurrentMediaTime()
        watching = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if app == .current { cameForward = CACurrentMediaTime() } else { before = app }
            }
        }
    }

    private init(tab: Tab, browser: Browser, from app: NSRunningApplication?, home: UUID?, size: NSSize?, remembersFrame: Bool, over: Bool) {
        self.tab = tab
        self.browser = browser
        self.home = home
        downloadSpace = home ?? browser.downloadSpace(for: tab) ?? browser.spaceID
        self.remembersFrame = remembersFrame
        cameFrom = app
        // Made at the size it comes in at, the page too: a page first laid
        // out at another size showed it for the first frames, a white page
        // in the top left of its card with the dark ground round it.
        let size = size ?? NSSize(width: 900, height: 640)
        holder = PageHolder(tab: tab, size: NSSize(
            width: max(size.width - 2 * LinkRoom.inset, 1),
            height: max(size.height - LinkRoom.bar - LinkRoom.inset, 1)
        ))
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        if over {
            let panel = FullScreenFrame(contentRect: NSRect(origin: .zero, size: size),
                                        styleMask: style.union(.nonactivatingPanel), backing: .buffered, defer: false)
            panel.hidesOnDeactivate = false
            window = panel
        } else {
            window = Frame(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: style, backing: .buffered, defer: false)
        }
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Moved by its strip as the browser's windows are, and by nothing
        // of AppKit's: the bar stands where a title bar would be.
        WindowDrag.keep(window)
        window.isReleasedWhenClosed = false
        // It comes and goes in one frame, as Little Arc does: AppKit's fade
        // on ordering out would leave a second picture of the page behind.
        window.animationBehavior = .none
        window.isOpaque = false
        window.backgroundColor = Palette.NS.ground
        window.minSize = NSSize(width: 420, height: 320)
        window.tabbingMode = .disallowed
        // The green light says full screen, which Frame turns into Open.
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        bar.raise = { [weak self] in self?.raise() }
        let room = NSHostingView(rootView: LinkRoom(
            browser: browser, tab: tab, finder: tab.finder, prefs: browser.prefs, bar: bar, steer: steer, holder: holder, home: home,
            keep: { [weak self] in self?.keep() },
            spaces: { [weak self] in self?.showSpaces() },
            asked: { [weak self] in self?.asking = $0 }
        ))
        self.room = room
        // The bar stands in the title bar, which is the point: no inset for it.
        room.safeAreaRegions = []
        room.sizingOptions = []
        // Inside a plain view, not the window's content view itself: as
        // that, the hosting view sizes the window to what SwiftUI would like,
        // on every layout and animated, and a page has no height of its own
        // to offer, so the window grew to the screen's while it came in.
        let content = NSView(frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size))
        content.wantsLayer = true
        room.frame = content.bounds
        room.autoresizingMask = [.width, .height]
        content.addSubview(room)
        window.contentView = content
        // Ours, where the bar puts them, in its middle.
        Lights.hideOwn(of: window)
        updateLevel()
    }

    /// Desktop Small Windows participate in normal click-to-front ordering.
    /// Only the nonactivating fullscreen panel needs to float while it owns
    /// the keyboard, including over a foreign Space with NSApp inactive.
    /// Once another window takes the keyboard, that panel must yield too.
    private func updateLevel() {
        window.level = window is FullScreenFrame && window.isKeyWindow ? .floating : .normal
    }

    func windowDidBecomeKey(_ notification: Notification) { updateLevel() }
    func windowDidResignKey(_ notification: Notification) { updateLevel() }

    // MARK: - where it stands

    /// With no user adjustment, most of the screen in its top right corner as
    /// Little Arc stands (20 pt in from the edge, under the menu bar), and
    /// never so big it could pass for the browser. A second one stands a
    /// step down and to the left of the last, so both can be seen.
    private static func place(_ asked: NSSize?, on screen: NSScreen, remembering: Bool) -> NSRect {
        let room = screen.visibleFrame
        let remembered = remembering ? rememberedFrame(in: room) : nil
        let size = remembered?.size ?? asked.map {
            NSSize(width: min(max($0.width, 420), room.width - 40), height: min(max($0.height + LinkRoom.bar + LinkRoom.inset, 320), room.height - 40))
        } ?? NSSize(
            width: min(max(room.width * 0.62, 560), 1100),
            height: min(max(room.height * 0.74, 420), 780)
        )
        var origin = remembered?.origin ?? NSPoint(x: room.maxX - corner - size.width, y: room.maxY - corner - size.height)
        if let last = open.last(where: { $0.window.isVisible })?.window.frame, room.intersects(last) {
            origin = NSPoint(x: last.maxX - 24 - size.width, y: last.maxY - 24 - size.height)
        }
        // Kept on the screen, however many came before it.
        return WindowPlacing.fitting(NSRect(origin: origin, size: size), in: room).integral
    }

    /// The same fitted frame is used before constructing the page holder,
    /// so its first viewport already has the restored dimensions.
    nonisolated static func rememberedFrame(in room: NSRect, store: UserDefaults = Store.settings) -> NSRect? {
        savedFrame(store: store).map { WindowPlacing.fitting($0, in: room) }
    }

    nonisolated private static func savedFrame(store: UserDefaults = Store.settings) -> NSRect? {
        guard let values = store.array(forKey: frameKey) as? [Double], values.count == 4,
              values.allSatisfy(\.isFinite), values[2] >= 420, values[3] >= 320 else { return nil }
        return NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private func rememberFrame() {
        guard remembersFrame, window.isVisible, !kept, !handed, !window.isMiniaturized,
              !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frame
        Store.settings.set([frame.minX, frame.minY, frame.width, frame.height].map { Double($0) }, forKey: Self.frameKey)
    }

    func windowWillMove(_ notification: Notification) {
        guard remembersFrame else { return }
        moving = true
        finishMoveWhenReleased()
    }

    private func finishMoveWhenReleased() {
        moveEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            guard let self, self.moving else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                self.finishMoveWhenReleased()
            } else {
                // performDrag hands tracking to the window server and
                // may never deliver a mouse-up event to this process.
                self.rememberFrame()
                self.moving = false
                self.moveEnd = nil
            }
        }
        moveEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: end)
    }

    func windowDidMove(_ notification: Notification) {
        // AppKit's user move is bracketed by will/did. Programmatic
        // setFrame, first placement and screen fitting only send didMove.
        guard moving else { return }
        rememberFrame()
        // Keep all intermediate drag positions eligible, then disarm so
        // a later programmatic move cannot replace the final user frame.
        if NSEvent.pressedMouseButtons & 1 == 0 {
            moving = false
            moveEnd?.cancel()
            moveEnd = nil
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) { rememberFrame() }

    /// From the screen's edge to the window, as Little Arc's (measured,
    /// 2560 x 1440: 20 pt in from the right).
    private static let corner: CGFloat = 20

    /// The screen the pointer is on, unless an app has it in full screen:
    /// a window of this app's made there is up and never seen, and the click
    /// seems to have done nothing. Then another screen, one that is free.
    /// An app in full screen is told by a window of its that covers its
    /// screen exactly, menu bar's height and all, which no window that is
    /// only as big as it can be does.
    private static func free(preferred: NSRect? = nil, screens: [NSScreen], mouse: NSPoint) -> NSScreen? {
        let ordered = screens.filter { $0.frame.contains(mouse) }
            + screens.filter { !$0.frame.contains(mouse) }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = ProcessInfo.processInfo.processIdentifier
        let top = screens.first?.frame.maxY ?? 0
        let whole: [CGRect] = windows.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowOwnerPID as String] as? Int32 != mine,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            // The window server counts down from the top of the first screen.
            return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
        let free = ordered.filter { screen in
            !whole.contains { $0.integral == screen.frame.integral }
        }
        return preferred.flatMap { frame in free.first { $0.visibleFrame.intersects(frame) } } ?? free.first
    }

    /// The screen the pointer is on, else the first.
    private static func underPointer(screens: [NSScreen], mouse: NSPoint) -> NSScreen? {
        screens.first { $0.frame.contains(mouse) } ?? screens.first
    }

    struct OwnFullscreenAdmission: Sendable {
        let screenIndex: Int
        let registeredNormalKeyOwner: Bool
        let appActive: Bool
        let visible: Bool
        let miniaturized: Bool
        let onActiveSpace: Bool
        let nativeFullscreen: Bool
        let settled: Bool
    }

    struct FullscreenAdmission: Equatable, Sendable {
        let screenIndex: Int?
        let over: Bool
    }

    /// Only upgrade the already-selected target. A remembered other screen
    /// and the foreign-fullscreen/free-screen policy keep their precedence.
    nonisolated static func fullscreenAdmission(
        legacyScreenIndex: Int?, legacyOver: Bool, pointerScreenIndex: Int?, own: OwnFullscreenAdmission?
    ) -> FullscreenAdmission {
        let legacy = FullscreenAdmission(screenIndex: legacyScreenIndex, over: legacyOver)
        guard !legacyOver, let target = legacyScreenIndex, target >= 0,
              let pointer = pointerScreenIndex, target == pointer,
              let own, own.screenIndex == target,
              own.registeredNormalKeyOwner, own.appActive, own.visible, !own.miniaturized,
              own.onActiveSpace, own.nativeFullscreen, own.settled else { return legacy }
        return FullscreenAdmission(screenIndex: target, over: true)
    }

    private static func ownFullscreen(in screens: [NSScreen]) -> OwnFullscreenAdmission? {
        // Unlike Links.window, a key window has no focused/last-visible
        // fallback. The reverse identity also excludes the detached inspector window.
        guard let key = NSApp.keyWindow,
              let owner = BrowserWindows.shared.browser(for: key),
              BrowserWindows.shared.window(for: owner) === key,
              owner.windowPurpose == .normal, !owner.privateBrowsing,
              let screen = key.screen, let index = screens.firstIndex(where: { $0 === screen })
        else { return nil }
        return OwnFullscreenAdmission(
            screenIndex: index, registeredNormalKeyOwner: true,
            appActive: NSApp.isActive, visible: key.isVisible, miniaturized: key.isMiniaturized,
            onActiveSpace: key.isOnActiveSpace, nativeFullscreen: key.styleMask.contains(.fullScreen),
            settled: BrowserWindows.shared.isSettledFullscreen(key))
    }

    /// Shown in the Space of an app in full screen instead of pulling the
    /// Mac to yab's desktop. AppKit lets only a window that is not itself a
    /// full-screen primary join one, so the green light goes; ⌃⌘F and Open
    /// still keep the page into the tabs.
    private func joinFullScreenSpace() {
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert([.fullScreenAuxiliary, .moveToActiveSpace])
    }

    /// In over the app you were in, whole in one frame as Little Arc's is,
    /// at its size from the first: a window grown into place is a window
    /// resized by the window server every frame, and its page laid out
    /// again every frame. Only this window comes forward, the browser's
    /// stays where it was.
    private func appear(at frame: NSRect) {
        window.setFrame(frame, display: false)
        // The card laid out before the first frame, so the page is at its
        // size before anything of it is seen.
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        if window is FullScreenFrame { return }
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        // yab brought forward for a link brings every window of its, the
        // browser's too, over the app you were in: back under it.
        if let app = cameFrom, let main = Links.window, main.isVisible, let over = LinkWindow.front(of: app) {
            main.order(.below, relativeTo: over)
        }
    }

    /// An app's window nearest the front, as the window server has them.
    private static func front(of app: NSRunningApplication) -> Int? {
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return listed.first {
            $0[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier && $0[kCGWindowLayer as String] as? Int == 0
        }?[kCGWindowNumber as String] as? Int
    }

    // MARK: - keys

    /// Its keys, before the browser's menus can take them for the browser's
    /// own tab: ⌘W closes it, ⌘O keeps it, ⌥⌘O asks which space to keep it
    /// in, ⌘R, ⌘., ⌘[ and ⌘] are the page's reload, stop, back and forward,
    /// as the bar's doors are, and ⌘← ⌘→ too outside text; ⌘F, ⌘G and
    /// Escape find on the page and ⌘P prints it, as in a tab. Editing keys
    /// go to the page as ever, and so does anything while something is
    /// being typed; any other command is the browser's, and brings its
    /// window to say so.
    func take(_ event: NSEvent) -> Bool {
        // Return and Escape for yab's question over this window, ⌘Q's,
        // before the page and this window's own keys, as in the browser.
        if Questions.shared.key(event, typing: tab.typing) { return true }
        // Return and Escape for what the page is asking, as in the browser.
        if let browser, browser.askKey(event, on: tab) { return true }
        // The browser's field raised over this page: its keys, as the
        // browser's window gives them to it.
        if let browser, browser.fieldGuest === tab, fieldKey(event, in: browser) { return true }
        let fieldUp = browser?.fieldGuest === tab
        // The list belongs to this page, before Return could submit its form.
        if !fieldUp, let browser, browser.autofillKey(event, on: tab) { return true }
        // Escape puts the find bar away, from the field or the page.
        if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, tab.finder.shown, !fieldUp {
            tab.finder.close()
            return true
        }
        // Into the browser's tabs, as the green light does (Frame). Held
        // down, it goes once.
        if Self.fullScreenKey(code: event.keyCode, flags: event.modifierFlags) {
            if !event.isARepeat { window.toggleFullScreen(nil) }
            return true
        }
        // fn F, View's full screen, before the page's WebKit view takes it.
        if Keymap.pressFunctionItem(for: event) { return true }
        guard let first = Hotkey(event) else { return false }
        let hotkey = Hotkey.first(event) { Keymap.shared.action(for: $0) }?.0 ?? first
        let flags = hotkey.flags
        let key = hotkey.key
        // The same assignments as the browser, applied to this window's page.
        // Here and not the menu's: the menu's action is about a browser tab.
        switch Keymap.shared.action(for: hotkey) {
        case .closeTab: window.performClose(nil); return true
        case .peekTab: keep(); return true
        // Through the bar's doors' steer, so the doors answer the keys.
        case .reload: steer.reload(tab); return true
        case .hardReload: tab.hardReload(); return true
        case .stopLoading: tab.stop(); return true
        case .back: steer.back(tab, byKey: true); return true
        case .forward: steer.forward(tab, byKey: true); return true
        // In a box they move the caret, as everywhere.
        case .backArrow, .forwardArrow:
            guard !tab.typing, !(window.firstResponder is NSTextView) else { return false }
            hotkey == Keymap.shared.keys(.backArrow) ? steer.back(tab, byKey: true) : steer.forward(tab, byKey: true)
            return true
        case .openAddress: raise(); return true
        case .copyAddress: copyPage(); return true
        case .copyMarkdownLink: copyPage(markdown: true); return true
        // The page's own find bar, as a tab's, over this window's page.
        case .find: if !tab.isBlank { tab.finder.open() }; return true
        case .findNext, .findPrevious:
            guard tab.finder.shown else { if !tab.isBlank { tab.finder.open() }; return true }
            tab.finder.step(forward: Keymap.shared.action(for: hotkey) == .findNext)
            return true
        case .print: Browser.printSheet(tab, in: window); return true
        case .extensions:
            if #available(macOS 15.4, *), !tab.isBlank { ExtensionPanel.shared.toggle(tab: tab, browser: browser) }
            return true
        default: break
        }
        if Keymap.shared.matches(event, .smallSpace) { showSpaces(); return true }
        guard flags.contains(.command) else { return false }
        // A key moved away from an action is nobody's (Keymap.nobodys).
        if Keymap.shared.nobodys(event) { return true }
        if tab.typing || window.firstResponder is NSTextView { return false }
        let own: Set<String> = ["c", "v", "x", "a", "z", "q", "h", "m", ",", "`", "←", "→", "↑", "↓", "⌫", "⌦"]
        if own.contains(key) || flags.contains(.control) { return false }
        Links.showBrowser(browser)
        return false
    }

    /// ⌘L, or a click on the address: the browser's field over this page.
    func raise() {
        guard let browser, !kept else { return }
        browser.edit(over: tab, in: window)
    }

    /// A copy asked for from the shared field says so in this window too.
    func copyPage(markdown: Bool = false) {
        if markdown { bar.copyMarkdown(tab) } else { bar.copy(tab.address) }
    }

    /// The field's keys while it stands over this page, as the browser's
    /// window takes them (ContentView.take): Escape one step at a time,
    /// the field's place, the row picked, the site searched, the address
    /// typed over, then the field; ⌘↩ and ⇧⌘↩ to a tab of its own.
    private func fieldKey(_ event: NSEvent, in browser: Browser) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
            if browser.leavePlace() || browser.leaveActions() || browser.unchoose() || browser.leaveScope() || browser.restore() { return true }
            browser.dismiss()
            return true
        }
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        let map = Keymap.shared
        if map.matches(event, .fieldCopy) { browser.submit(.behind); return true }
        if map.matches(event, .fieldAhead) { browser.submit(.ahead); return true }
        if map.matches(event, .fieldAlternate) { browser.submitAlternate(); return true }
        return browser.fieldKey(event)
    }

    // MARK: - keeping and closing

    /// Into the row, beside the tab on screen, and in front, in one frame
    /// as Little Arc hands its page over: no picture flies, the window is
    /// gone and the page is the browser's tab where it was.
    ///
    /// `space`: the space picked from the button's list, which the window
    /// goes to with the page; nil, ⌘O, for the one on screen.
    func keep(into space: UUID? = nil) {
        guard let browser, !kept else { return }
        if browser.fieldGuest === tab { browser.dismiss() }
        // Always into a space's store, the one on screen unless another
        // was picked: the page may have come up in another space's.
        into = space.flatMap { id in browser.spaces.contains { $0.id == id } ? id : nil } ?? place(in: browser)
        kept = true
        if let into { LinkRoutes.shared.noteKept(tab.address, into: into) }
        hand()
    }

    /// The page handed to the browser. This window is out of sight at once
    /// and stays the page's owner until the stage has it: closing it first
    /// takes WebKit out of a window before SwiftUI can attach it there.
    private func hand() {
        guard let browser, !handed else { return }
        handed = true
        // Its native frame must not intercept the receiving page.
        window.ignoresMouseEvents = true
        hide()
        tab.page.autoresizingMask = []
        let now = browser.takeIn(tab, into: into ?? browser.spaceID)
        carried = now !== tab
        Links.showBrowser(browser)
        let target = BrowserWindows.shared.window(for: browser) ?? Links.window
        if let target { window.order(.above, relativeTo: target.windowNumber) }
        // A blank tab shows the browser's address field, not a WebKit
        // stage. There is no page presentation to wait for in that case.
        if now.isBlank { return window.close() }
        StageView.afterHandoff(now.page, owner: now.id, window: { [weak browser] in
            browser.flatMap { BrowserWindows.shared.window(for: $0) } ?? Links.window
        }, cancelled: { [weak browser, weak now] in
            guard let browser, let now else { return true }
            return now.gone || !browser.stages.contains(now.id)
        }, attached: { [weak self] _ in self?.window.close() },
           done: { [weak self] _ in self?.window.close() })
    }

    /// The frame round the page, the bar and the backdrop, gone in the
    /// frame the page is handed over: on its layer, with no shadow left
    /// for the window server to draw round nothing.
    private func hide() {
        guard let layer = window.contentView?.layer else { return window.orderOut(nil) }
        window.hasShadow = false
        // The native backing is outside the content layer's opacity.
        // Once WebKit leaves, it otherwise remains as an empty gray panel
        // until this window can finally close.
        window.backgroundColor = .clear
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        CATransaction.commit()
    }

    /// The spaces to keep it into, a list of yab's own (DropMenu's) hung
    /// from the window's top right corner over the button, as Little Arc's
    /// "Search spaces…" is: a search on top, the one on screen first, then
    /// the others in their order, each saying so when its sign-ins are its
    /// own and the page opens there afresh. In and out in one frame.
    func showSpaces() {
        guard let browser, !kept, let room,
              LinkSpaces.shown(browser.spaces, on: browser.spacesShown) else { return }
        let spot = place(in: browser)
        let dark = room.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let spaces = LinkSpaces.order(browser.spaces, current: spot)
        var lines = spaces.map { space in
            DropList.Line(title: space.name, picture: LinkSpaces.mark(space, prefs: browser.prefs, dark: dark),
                          note: browser.signsInAgain(tab, in: space.id) ? LinkSpaces.again : nil)
        }
        let always = self.always(in: browser, place: spot)
        if let always {
            lines.append(DropList.Line(title: always.title, picture: always.on ? MenuMark.image("checkmark") : nil))
        }
        let list = DropList(options: lines, chosen: 0, divideBefore: always == nil ? nil : spaces.count,
                            inset: DropFace.inset, searchWords: LinkSpaces.search, alwaysSearch: true)
        let frame = window.frame
        let corner = NSPoint(x: frame.maxX - LinkSpaces.inset, y: frame.maxY - LinkSpaces.inset)
        DropPopup.show(list, under: room, corner: corner, width: LinkSpaces.listWidth, fade: false) { [weak self] index in
            guard let self, let index else { return }
            if spaces.indices.contains(index) { keep(into: spaces[index].id) } else { always?.act() }
        }
    }

    /// Into the row with no window ever seen: there was nowhere to see it.
    func settle() {
        guard let browser, !kept else { return }
        kept = true
        handed = true
        window.orderOut(nil)
        tab.page.autoresizingMask = []
        carried = browser.takeIn(tab, into: place(in: browser)) !== tab
        Links.showBrowser(browser)
        window.close()
    }

    /// Where Open keeps it: the space its route sent it to while that
    /// space is there, the one on screen otherwise.
    private func place(in browser: Browser) -> UUID {
        home.flatMap { id in browser.spaces.contains { $0.id == id } ? id : nil } ?? browser.spaceID
    }

    /// The list's last line: this site's links always to the space Open
    /// names, or, ticked, the route there is, taken away by choosing it.
    /// Nothing is said after: the next link from the site shows it.
    private func always(in browser: Browser, place: UUID) -> (title: String, on: Bool, act: () -> Void)? {
        guard let site = LinkRoutes.site(of: tab.address) else { return nil }
        let routes = LinkRoutes.shared
        if let route = routes.route(site: site), let space = browser.spaces.first(where: { $0.id == route.space }) {
            return ("Always Open \(site) in \(space.name)", true, { routes.remove(site) })
        }
        guard let space = browser.spaces.first(where: { $0.id == place }) else { return nil }
        return ("Always Open \(site) in \(space.name)", false, { routes.set(site, to: space.id) })
    }

    /// Closed by ⌘W, its red light, or the page itself.
    func close() { window.performClose(nil) }

    /// Closing one leaves yab in front, and AppKit would give the key to
    /// the browser's window and bring it up: so another small window, if
    /// one is open, or else the app this one came up over, before AppKit
    /// picks. Kept, the browser is what was asked for.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !kept, window.isKeyWindow else { return true }
        if let next = LinkWindow.open.last(where: { $0 !== self && !$0.kept }) {
            next.window.makeKeyAndOrderFront(nil)
        } else if let app = cameFrom, !app.isTerminated, NSApp.isActive {
            LinkWindow.back(to: app)
        }
        return true
    }

    /// The app gone back to, and the browser's window, which AppKit raises
    /// as it gives it the key in the moment before yab steps back, put
    /// under it again once yab has.
    private static var stepping: Any?
    private static func back(to app: NSRunningApplication) {
        app.activate()
        if let stepping { NotificationCenter.default.removeObserver(stepping) }
        stepping = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let stepping { NotificationCenter.default.removeObserver(stepping) }
                stepping = nil
                if let main = Links.window, main.isVisible, let over = front(of: app) {
                    main.order(.below, relativeTo: over)
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Last, once the page is let go or in the row: its move is told before its window closes.
        defer { if #available(macOS 15.4, *) { Extensions.all.forEach { $0.unfollow(self) } } }
        moveEnd?.cancel()
        moveEnd = nil
        moving = false
        LinkWindow.open.removeAll { $0 === self }
        if let browser, browser.fieldGuest === tab { browser.dismiss() }
        let pending = kept && !handed
        handed = true
        guard !kept || carried || pending else { return }
        browser?.letGo(outside: tab)
    }
}

// MARK: - the window's content

/// The page's card. The page is laid in by hand, as the stage lays it:
/// SwiftUI never holds it, so the browser's stage can take it from here
/// without either side minding, and once it has, nothing here takes it back.
final class PageHolder: NSView {
    private let tab: Tab
    /// The swipe's pill over this page, as the stage has one over a tab's
    /// (PullHost): a peek's page swiped back and forward but drew nothing,
    /// the tab's swipes going to the stage's view, out of sight under the
    /// peek (feedback #212).
    private let pull = PullView()
    /// Whoever drew the tab's swipes before this holder took them, given
    /// them back when it goes.
    private weak var lent: PullView?
    /// A band along the holder's top, over none of the page: a peek's
    /// address (PeekBand). The page and its swipes take the room under it.
    var band: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let band { addSubview(band) }
            fit()
        }
    }

    /// Where the page lies in the holder: all of it, less the band's room.
    var pageFrame: NSRect {
        let tall = band?.frame.height ?? 0
        return NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, bounds.height - tall))
    }

    init(tab: Tab, size: NSSize = NSSize(width: 900, height: 600)) {
        self.tab = tab
        super.init(frame: NSRect(origin: .zero, size: size))
        // This holder owns the viewport. SwiftUI can resize its AppKit view
        // without scheduling layout, so an autoresizing mask is not enough.
        autoresizesSubviews = false
        wantsLayer = true
        layer?.cornerRadius = Radius.surface
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        let web = tab.page
        web.frame = bounds
        web.autoresizingMask = []
        addSubview(web)
        pull.frame = bounds
        addSubview(pull)
    }

    /// The tab's swipes are drawn here while its page is here and shown.
    private func claimPull() {
        let here = window != nil && tab.builtPage?.superview === self
        if here, tab.pullView !== pull {
            if tab.pullView?.owner === tab { lent = tab.pullView }
            pull.owner = tab
            tab.pullView = pull
            pull.show(tab.pull, of: tab)
        } else if !here, tab.pullView === pull {
            pull.show(nil, of: tab)
            tab.pullView = lent?.owner === tab ? lent : nil
        }
    }

    required init?(coder: NSCoder) { nil }

    override var frame: NSRect {
        didSet { fit() }
    }

    override var bounds: NSRect {
        didSet { fit() }
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        fit()
    }

    override func setBoundsSize(_ size: NSSize) {
        super.setBoundsSize(size)
        fit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fit()
        claimPull()
    }

    override func layout() {
        super.layout()
        fit()
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        guard subview === tab.builtPage else { return }
        // A beat later, the page gone: its swipes back to whoever drew them
        // before. Never a weak reference to self here: AppKit takes the
        // subviews out in the holder's own dealloc too, and forming one then
        // is fatal (a peek kept as a tab crashed, 682bfa04).
        let tab = tab, pull = pull, lent = lent
        DispatchQueue.main.async {
            let holder = pull.superview
            let here = holder?.window != nil && tab.builtPage?.superview === holder
            guard !here, tab.pullView === pull else { return }
            pull.show(nil, of: tab)
            tab.pullView = lent?.owner === tab ? lent : nil
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // The page laid in again (a peek kept and shown again): the pill
        // stays over it.
        guard subview === tab.builtPage else { return }
        if pull.superview === self { addSubview(pull, positioned: .above, relativeTo: subview) }
        claimPull()
    }

    /// Element fullscreen borrows the view; unlike StageView, this holder's
    /// layout only sizes an attached page. Return only the same live tab's
    /// detached view, never a page already handed to the browser or a peek.
    func returnFromFullscreen(_ page: ChromiumPage) {
        guard window != nil, !tab.gone, tab.builtPage === page,
              page.superview == nil else { return }
        page.autoresizingMask = []
        page.frame = bounds
        addSubview(page, positioned: .below, relativeTo: pull)
        claimPull()
    }

    private func fit() {
        let page = pageFrame
        if let band {
            let room = NSRect(x: bounds.minX, y: page.maxY, width: bounds.width, height: band.frame.height)
            if band.frame != room { band.frame = room }
        }
        if pull.frame != page { pull.frame = page }
        // Once handed to a stage, only that stage may size the same page.
        guard let web = tab.builtPage, web.superview === self, web.frame != page else { return }
        web.frame = page
    }
}

private struct Holding: NSViewRepresentable {
    let holder: PageHolder
    func makeNSView(context: Context) -> PageHolder { holder }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PageHolder, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
    func updateNSView(_ view: PageHolder, context: Context) {}
}

/// The bar's own state: the field being typed in, and the copies made
/// from it, counted so the tick knows when to show.
@MainActor
final class LinkBarState: ObservableObject {
    /// A probe's pointer over the field (Bench `fieldhover`).
    @Published var pointed = false
    /// This window's own corner: a copy says so here, as the browser's
    /// corner says it there (Toast.swift), and in no other window.
    let toaster = Toaster()
    let tidier = Tidier()
    /// The browser's field, raised over this window's page (LinkWindow).
    var raise: () -> Void = {}

    /// The page's address, to paste anywhere.
    func copy(_ url: URL?) {
        guard let url else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(Diary.shareable(url).absoluteString, forType: .string)
        toaster.pop(keys: Teach.shared.keys(after: .copyAddress, action: .copyAddress), feedback: .success)
    }

    /// ⌥⇧⌘C: the page as a Markdown link, said as the browser says it.
    func copyMarkdown(_ tab: Tab) {
        guard let page = MarkdownLink.page(tab) else { return }
        MarkdownLink.copy([page])
        toaster.pop("Markdown link copied", mark: "link",
                    keys: Teach.shared.keys(after: .markdownLink, action: .copyMarkdownLink), feedback: .success)
    }
}

/// The window as Little Arc has it and the browser's own window wears it:
/// its backdrop, the site's color or the one picked, with its grain, round
/// a bar and the page laid on it as a card. On "Edge to edge" too: the
/// frame is what says this is the small window, so there it is the gray.
private struct LinkRoom: View {
    /// The bar's height, the lights in its middle.
    static let bar: CGFloat = 44
    /// The page's air from the window's edges.
    static let inset: CGFloat = Backdrop.inset

    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var finder: Finder
    @ObservedObject var prefs: Preferences
    @ObservedObject var bar: LinkBarState
    let steer: HelmSteer
    let holder: PageHolder
    let home: UUID?
    let keep: () -> Void
    let spaces: () -> Void
    let asked: (Bool) -> Void
    @Environment(\.colorScheme) private var scheme

    /// The look of the space Open keeps it into: its route's own when that
    /// is another space, the window's as worn now otherwise.
    private var paint: SpacePaint {
        let routed = home.flatMap { id in id == browser.spaceID ? nil : browser.spaces.first { $0.id == id }?.paint }
        return routed ?? SpacePaint(prefs)
    }

    var body: some View {
        let dark = scheme == .dark
        let paint = paint
        let swatch = prefs.backdrop == .none ? Swatch.gray.color(dark: dark, custom: prefs.backdropColor) : paint.color(dark: dark)
        Worn(tab: tab, mode: prefs.backdrop, swatch: Tone(swatch, lifted: true)) { tone in
            ZStack(alignment: .top) {
                // The gradient is the picked color's: the site's color wears none.
                BackdropFill(color: tone?.color ?? Color(nsColor: swatch), grain: prefs.backdrop == .none ? prefs.grain : paint.grain,
                             colors: prefs.backdrop == .color ? paint.gradient(dark: dark) : [])
                // The picked color's drawings, as the big window wears them
                // (SpaceWash.worn): the site's color and the gray wear none.
                if prefs.backdrop == .color {
                    LookDrawingsFill(drawings: paint.drawings, strength: paint.drawingsStrength, ground: swatch)
                }
                DragStrip()
                VStack(spacing: 0) {
                    LinkBar(browser: browser, tab: tab, bar: bar, steer: steer, home: home, keep: keep, spaces: spaces)
                        .frame(height: Self.bar)
                        .toned(tone)
                    Holding(holder: holder)
                        .overlay(alignment: .bottomLeading) { LinkStatusPill(tab: tab.id) }
                        .overlay(alignment: .topLeading) { PageSuggestions(browser: browser, tab: tab) }
                        // ⌘F, the tab's own bar in the page's top corner.
                        .overlay(alignment: .topTrailing) {
                            if finder.shown {
                                FindBar(finder: finder) { withAnimation(Motion.depart) { finder.close() } }
                                    .padding([.top, .trailing], Metrics.rim)
                                    .transition(.opacity.combined(with: .offset(y: -4)))
                            }
                        }
                        .animation(Motion.arrive, value: finder.shown)
                        // "Link copied", from under the page's top edge in
                        // its corner, as the browser's corner says it.
                        .overlay(alignment: .topTrailing) {
                            Notice(browser: browser, toaster: bar.toaster, tidier: bar.tidier, agents: Agents.shared,
                                   top: Metrics.rim, browsers: false)
                                .padding(.trailing, Metrics.rim)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
                                .strokeBorder(Palette.ink.opacity(0.07), lineWidth: 0.5)
                                .allowsHitTesting(false)
                        )
                        .padding([.horizontal, .bottom], Self.inset)
                }
            }
        }
        // What the page asks, alert() and the rest, over the window as
        // over the browser's: without it the question waits on a tab
        // nobody can see, and the page with it.
        .overlay { AskLayer(browser: browser, page: tab) }
        // What yab asks, ⌘Q's question among them, here too: only in the
        // browser's window, it stood behind this one, out of sight, and
        // Escape here went to the page (#178). Its keys: LinkWindow.take.
        .overlay { QuestionStand(keyed: { _ in browser.fieldGuest !== tab }, shown: asked) }
        // ⌘L, or a click on the address: the browser's own field over this
        // page, in one frame, as Little Arc raises its command bar.
        .overlay {
            if browser.fieldGuest === tab {
                Omnibox(browser: browser, inset: 0)
            }
        }
        // The field gone, the keyboard back to the page.
        .onChange(of: browser.fieldGuest === tab) { _, up in
            if !up, let web = tab.builtPage, let window = web.window { window.makeFirstResponder(web) }
        }
        .ignoresSafeArea()
    }
}

/// The lights, the field with the site in it and back, forward and reload
/// in its left end, and the one thing to press.
private struct LinkBar: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var bar: LinkBarState
    let steer: HelmSteer
    let home: UUID?
    let keep: () -> Void
    let spaces: () -> Void
    @Environment(\.tone) private var tone

    var body: some View {
        HStack(spacing: 8) {
            Lights()
                .frame(width: Lights.run, height: LinkRoom.bar)
                .padding(.leading, 18 - Lights.lead)
            LinkField(browser: browser, tab: tab, bar: bar, steer: steer)
            OpenButton(browser: browser, bar: bar, home: home, action: keep, spaces: spaces)
        }
        .padding(.trailing, LinkRoom.inset)
    }
}

/// A hostless page's own caption, without consulting another tab or history.
/// A completed untitled file already has an address worth showing.
enum LinkCaption {
    static func hostless(_ url: URL, title: String, loading: Bool) -> String {
        if !title.isEmpty { return title }
        if url.isFileURL, !loading { return Address.shown(url) }
        return "Loading"
    }
}

/// The caption opens the field on a click and moves the window on a drag.
/// Once a press has moved, returning to its start cannot make it a click.
struct LinkFieldPress {
    private var origin: NSPoint?
    private var moved = false

    mutating func begin(at point: NSPoint) {
        origin = point
        moved = false
    }

    mutating func drag(to point: NSPoint) -> Bool {
        guard let origin, !moved, StripPress.drags(point.x - origin.x, point.y - origin.y) else { return false }
        moved = true
        return true
    }

    mutating func end(at point: NSPoint, inside: Bool) -> Bool {
        defer { origin = nil; moved = false }
        guard let origin, !moved, inside else { return false }
        return !StripPress.drags(point.x - origin.x, point.y - origin.y)
    }
}

/// A native handle like the strips, confined to the caption between the
/// doors and the copy button. The editor above it keeps all its presses.
struct LinkFieldHandle: NSViewRepresentable {
    let enabled: Bool
    let click: () -> Void

    func makeNSView(context: Context) -> Handle { Handle() }

    func updateNSView(_ view: Handle, context: Context) {
        view.enabled = enabled
        view.click = click
    }

    final class Handle: NSView, WindowHandle {
        var enabled = true {
            didSet {
                if !enabled { press = nil; decision = LinkFieldPress() }
            }
        }
        var click: (() -> Void)?
        private var press: NSEvent?
        private var decision = LinkFieldPress()

        override func hitTest(_ point: NSPoint) -> NSView? {
            enabled ? super.hitTest(point) : nil
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard enabled else { return }
            press = event
            decision.begin(at: event.locationInWindow)
        }

        override func mouseDragged(with event: NSEvent) {
            guard enabled, let window, let press, decision.drag(to: event.locationInWindow) else { return }
            guard !window.styleMask.contains(.fullScreen) else { return }
            window.performDrag(with: press)
        }

        override func mouseUp(with event: NSEvent) {
            defer { press = nil }
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            if decision.end(at: event.locationInWindow, inside: enabled && inside) { click?() }
        }
    }
}

/// The site, written as the address bar writes it, in a field of its own;
/// a click, or ⌘L, and the browser's field comes up over the page with
/// the whole address in it, to change, as Little Arc's command bar does. Under the
/// pointer its left end has the browser's own doors, reload, back and
/// forward, grayed where there is nowhere to go and held for the pages that
/// way, and its right end the link, which copies it, and Site Controls. Out from under it the
/// field is the site alone, but for the stop while the page is coming and
/// a door a key just used, shown a moment. The doors keep their room
/// either way, so the site never moves.
private struct LinkField: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var bar: LinkBarState
    @ObservedObject var steer: HelmSteer
    @Environment(\.tone) private var tone
    @State private var hovering = false
    @State private var flashing = false
    @State private var unflash: DispatchWorkItem?
    @State private var linkHovering = false
    @ObservedObject private var controls = SiteControlsState.shared

    private static let height: CGFloat = 28
    /// The link's plate, and Site Controls' beside it.
    private static let plate: CGFloat = 20
    /// Doors 2 in from the field's edges, a radius to match.
    private static let doors = Door.Size(side: height - 4, glyph: 11, gap: 0)
    /// Room for the site clear of the doors, on both sides so it stays centered.
    private static let words = doors.helm + 6

    var body: some View {
        ZStack {
            words
                .sidebarFont(size: 13)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, Self.words)
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .contentShape(Rectangle())
                .overlay {
                    LinkFieldHandle(enabled: browser.fieldGuest !== tab, click: bar.raise)
                        .padding(.leading, 2 + Self.doors.helm) // design: an undrawn hit area, clear of the doors
                        .padding(.trailing, 25 + (tab.isBlank ? 0 : Self.plate + 2)) // design: an undrawn hit area, clear of the copy button and Site Controls
                }
            HStack(spacing: 0) {
                Helm(browser: browser, tab: tab, reads: false, steer: steer, resting: !(lit || flashing), reloadFirst: true)
                    .environment(\.doorSize, Self.doors)
                    .animation(Motion.quick, value: lit || flashing)
                Spacer(minLength: 0)
                copy
                if !tab.isBlank { controlsDoor.padding(.leading, 2) }
            }
            .padding(.leading, 2)
            .padding(.trailing, 5) // design: as it was, only moved out of the old editing branch: the doors 2 in, the link's 20 pt plate 4 in round its mark
        }
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(field)
        )
        .onHover { hovering = $0 }
        .onChange(of: steer.backs) { flash() }
        .onChange(of: steer.forwards) { flash() }
        .onChange(of: steer.reloads) { flash() }
    }

    /// A key's door shown while it kicks, so ⌘[ is seen to be back.
    private func flash() {
        guard !lit else { return }
        unflash?.cancel()
        flashing = true
        let work = DispatchWorkItem { flashing = false }
        unflash = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// Under the pointer, or a probe's.
    private var lit: Bool { hovering || bar.pointed }

    /// The field on the frame: the live tab's chip, lifted off the color,
    /// a touch brighter under the pointer.
    private var field: Color {
        let base = Palette.wash(on: tone)
        guard lit else { return base }
        return tone?.scheme == .dark ? .white.opacity(0.18) : .white.opacity(0.85)
    }

    private var words: Text {
        let ink = Palette.ink
        let muted = Palette.muted(on: tone)
        guard let url = tab.address else { return Text("Search or enter address").foregroundStyle(muted) }
        guard let raw = url.host(), !raw.isEmpty else {
            return Text(LinkCaption.hostless(url, title: tab.title, loading: tab.loading)).foregroundStyle(muted)
        }
        let host = raw.lowercased().hasPrefix("www.") ? String(raw.dropFirst(4)) : raw
        let owner = Browser.site(host)
        let front = host.count > owner.count && host.lowercased().hasSuffix(owner) ? String(host.dropLast(owner.count)) : ""
        let site = Text(front).foregroundStyle(muted) + Text(host.dropFirst(front.count)).foregroundStyle(ink)
        return url.scheme?.lowercased() == "http" ? Text("Not secure  ").foregroundStyle(muted) + site : site
    }

    private var copy: some View {
        Button { bar.copy(tab.address) } label: {
            CopyMark(ticked: false, side: (10 * Glyphs.scale).rounded())
                .foregroundStyle(linkHovering ? Palette.ink : Palette.muted(on: tone))
                .frame(width: Self.plate, height: Self.plate)
                .background(
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .fill(linkHovering ? Palette.hover(on: tone) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: ButtonSize.small.pressed))
        .focusable(false)
        .keyTip("Copy URL", shortcut: "Copy URL")
        .onHover { linkHovering = $0 }
        .opacity(lit && tab.address != nil ? 1 : 0)
        .allowsHitTesting(lit)
        .animation(Motion.quick, value: lit)
    }

    /// Shown with the link, and kept while its panel hangs from it.
    private var controlsDoor: some View {
        let shown = lit || controls.openFor == tab.id
        return SiteControlsDoor(browser: browser, tab: tab, side: Self.plate, corner: Radius.small, glyph: 11)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .animation(Motion.quick, value: shown)
    }
}

/// Open, and its key: a card of its own on the frame, white on a
/// light one, a lighter glass on a dark one. With more than one space it
/// names the one on screen, and a chevron on its right end, a second
/// press on the same card, opens the list of spaces to keep it in.
private struct OpenButton: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var hotkeys = Hotkeys.shared
    @ObservedObject private var spaceKey = Keymap.shared.slot(.smallSpace)
    let bar: LinkBarState
    /// The space a route sent the link to, named rather than the one on screen.
    let home: UUID?
    let action: () -> Void
    let spaces: () -> Void
    @Environment(\.tone) private var tone
    @State private var hovering = false
    @State private var chevronHovering = false

    var body: some View {
        let place = home.flatMap { id in browser.spaces.contains { $0.id == id } ? id : nil } ?? browser.spaceID
        let name = LinkSpaces.name(browser.spaces, current: place, on: browser.spacesShown)
        let openKeys = hotkeys.keys("Open Peek as Tab")
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 6) {
                    (name.map { Text("Open in ") + Text($0).fontWeight(.semibold) } ?? Text("Open"))
                        .sidebarFont(size: 12.5)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Its own width, measured, up to the cap: a
                        // flexible frame would take all the bar offers.
                        .frame(width: LinkSpaces.wordsWidth(name))
                    // The plate 4 in from the button's edges, as a .yab's is.
                    KeyGlyphs(keys: openKeys, size: 12.5, tint: Palette.muted(on: tone))
                        .environment(\.keyPlate, KeyPlate(height: 28 - 2 * ButtonSize.regular.keyInset, pull: 0, lead: (10 - 6) / 2))
                }
                .modifier(LeadingRoom(padding: 10))
                .padding(.trailing, ButtonSize.regular.keyInset)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: ButtonSize.small.pressed))
            .focusable(false)
            .keyTip(name.map { "Open in \($0)" } ?? "Open", shortcut: "Open Peek as Tab")
            .onHover { hovering = $0 }
            if name != nil {
                Rectangle()
                    .fill(Palette.ink.opacity(0.1))
                    .frame(width: 0.5, height: 16)
                Button(action: spaces) {
                    Symbol("chevron.down", size: 10, weight: .semibold)
                        .foregroundStyle(chevronHovering ? Palette.ink : Palette.muted(on: tone))
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: ButtonSize.small.pressed))
                .focusable(false)
                .keyTip("Open in Another Space", keys: spaceKey.keys?.text)
                .onHover { chevronHovering = $0 }
            }
        }
        // As wide as its words, keys and chevron, and no wider.
        .fixedSize()
        .modifier(SplitFace(lit: hovering || chevronHovering))
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: chevronHovering)
    }
}

/// What the small window's button knows of the spaces: whether to name
/// one at all, which, and the order its list shows them in.
enum LinkSpaces {
    /// The words under a space whose sign-ins are its own: the page opens
    /// there by its address, signed in as that space is.
    static let again = "Signs in again"
    /// The list's search while nothing is typed in it.
    static let search = "Search spaces\u{2026}"
    /// The list's width, and how far in from the window's top right
    /// corner it hangs: Little Arc's, measured (244 pt, 4 pt in).
    static let listWidth: CGFloat = 244
    static let inset: CGFloat = 4

    /// The widest "Open in <name>" is drawn; a longer name ends in "…".
    static let widest: CGFloat = 180

    /// How wide "Open" or "Open in <name>" is drawn at the button's type,
    /// with the name semibold, up to `widest`.
    static func wordsWidth(_ name: String?) -> CGFloat {
        guard let name else {
            return ceil(("Open" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5)]).width) + 1
        }
        let open = ("Open in " as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5)]).width
        let named = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]).width
        // A point spare, so a name that just fits isn't cut for a rounding.
        return min(widest, ceil(open + named) + 1)
    }

    /// Named, with a list, only when there is somewhere else to keep it.
    static func shown(_ spaces: [Space], on: Bool) -> Bool { on && spaces.count > 1 }

    /// The space on screen's name, or nil for the plain "Open" button.
    static func name(_ spaces: [Space], current: UUID, on: Bool) -> String? {
        guard shown(spaces, on: on) else { return nil }
        return spaces.first { $0.id == current }?.name
    }

    /// The one on screen first, then the others in their order.
    static func order(_ spaces: [Space], current: UUID) -> [Space] {
        spaces.filter { $0.id == current } + spaces.filter { $0.id != current }
    }

    /// Its emoji on its color, as the tray shows it, for a line of the list.
    @MainActor
    static func mark(_ space: Space, prefs: Preferences, dark: Bool) -> NSImage {
        let color = (space.paint ?? SpacePaint(prefs)).color(dark: dark)
        let side = MenuMark.side
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: Radius.small, yRadius: Radius.small).fill()
            Spaces.picture(emoji: space.icon, side: side * 0.72).draw(in: rect.insetBy(dx: side * 0.14, dy: side * 0.14))
            return true
        }
    }
}
