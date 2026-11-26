import AppKit
import SwiftUI
import YabCoreClient

/// Uses the same popover and button anchor as WebKit's extension popup,
/// while the content and input remain owned by Chromium's native widget.
@MainActor
final class ChromiumPopupHost: NSObject, ObservableObject, NSPopoverDelegate {
    static let shared = ChromiumPopupHost()
    private var popover: NSPopover?
    private var popup: ChromiumExtensionPopup?
    private weak var pendingPopup: ChromiumExtensionPopup?
    private weak var pendingPage: ChromiumPage?
    private weak var page: ChromiumPage?
    private weak var anchor: ChromiumPopupAnchor.View?
    private var following: Timer?
    private var closedOnButton: (String, Date)?
    /// The sliders' list, up until the popup pressed in it can take it over,
    /// as WebKit's does (ExtensionPanel.handOver).
    private var taken: (id: String, popover: NSPopover?)?
    private weak var pressedAnchor: ChromiumPopupAnchor.View?
    private var edgeAnchor: ChromiumPopupAnchor.View?
    /// The popover of a popup Chrome closed for its own replacement, up
    /// until the replacement's first frame takes it over (`replace`).
    private var heldOver: (popover: NSPopover, extensionID: String, fromDoor: Bool)?
    private weak var heldPage: ChromiumPage?
    private var buttonMonitor: Any?
    private var followedRect: CGRect?
    @Published private(set) var shownExtensionID: String?
    @Published private(set) var fromDoor = false
    var isShown: Bool { popover?.isShown == true }

    /// The sliders hold a popup of this tab, pressed in their list.
    func shownFromDoor(for tab: Tab) -> Bool { fromDoor && shownExtension(for: tab) != nil }

    /// Pressed in the sliders' list. `knownPopup` false: Chrome will show
    /// nothing, the list goes now; unknown, it goes if no popup comes soon.
    func expect(_ id: String, page: ChromiumPage, list: NSPopover?, knownPopup: Bool?) {
        if let tab = page.navigationTab {
            pressedAnchor = ChromiumPopupAnchor.View.find(tab: tab,
                id: list == nil ? id : ChromiumPopupAnchor.sliders, window: page.window)
        }
        guard let list else { taken = nil; return }
        taken = (id, list)
        if knownPopup == false { dropList(); return }
        let wait: TimeInterval = knownPopup == true ? 3 : 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak list] in
            guard let self, let list, self.taken?.popover === list else { return }
            self.dropList()
        }
    }

    func dropList() {
        let list = taken?.popover
        taken?.popover = nil
        list?.close()
    }

    /// Where the popover will hang: the pin, or the sliders with no pin or
    /// when it was pressed in their list.
    private func hang(_ popup: ChromiumExtensionPopup, page: ChromiumPage) -> ChromiumPopupAnchor.View? {
        if self.popup === popup, self.page === page, let anchor, anchor.usable(in: page.window) { return anchor }
        guard let tab = page.navigationTab else { return nil }
        if let pressedAnchor, pressedAnchor.tab === tab, pressedAnchor.usable(in: page.window),
           pressedAnchor.id == popup.extensionID || pressedAnchor.id == ChromiumPopupAnchor.sliders {
            return pressedAnchor
        }
        let pin = taken?.id == popup.extensionID ? nil : ChromiumPopupAnchor.View.find(tab: tab, id: popup.extensionID, window: page.window)
        if let real = pin ?? ChromiumPopupAnchor.View.find(tab: tab, id: ChromiumPopupAnchor.sliders, window: page.window) { return real }
        // An API/shortcut can open a popup with both the sidebar and address
        // bar tucked away. Keep it on this page's trailing top corner; there
        // is no hidden control to hang from and no new visible control.
        guard page.window != nil, page.bounds.width > 0, page.bounds.height > 0 else { return nil }
        if edgeAnchor?.superview !== page {
            edgeAnchor?.removeFromSuperview()
            let view = ChromiumPopupAnchor.View(tab: tab, id: "page-popup-edge")
            view.autoresizingMask = [.minXMargin, .minYMargin]
            page.addSubview(view)
            edgeAnchor = view
        }
        edgeAnchor?.frame = CGRect(x: max(0, page.bounds.width - 32), y: max(0, page.bounds.height - 32),
                                   width: min(32, page.bounds.width), height: min(32, page.bounds.height))
        return edgeAnchor
    }

    func placeProducer(_ popup: ChromiumExtensionPopup, page: ChromiumPage) {
        guard let anchor = hang(popup, page: page), let window = anchor.window else { return }
        popup.place(under: window.convertToScreen(anchor.convert(anchor.bounds, to: nil)), on: window.screen)
    }

    func shownExtension(for tab: Tab) -> String? {
        guard page?.navigationTab === tab, isShown else { return nil }
        return shownExtensionID
    }

    func toggleClosed(page: ChromiumPage, extensionID: String) -> Bool {
        if let closedOnButton, closedOnButton.0 == extensionID, Date().timeIntervalSince(closedOnButton.1) < 0.3 {
            self.closedOnButton = nil
            return true
        }
        if (self.page === page && popup?.extensionID == extensionID) ||
            (page.extensionPopup?.closed == false && page.extensionPopup?.extensionID == extensionID) {
            close(); return true
        }
        close()
        return false
    }

    private var traceFrame: String {
        let window = popover?.contentViewController?.view.window
        let view = popover?.contentViewController?.view
        return "popover \(popover?.contentSize ?? .zero) window \(window?.frame ?? .zero) view \(view?.frame ?? .zero) key \(window?.isKeyWindow ?? false) active \(NSApp.isActive)"
    }

    func receive(_ popup: ChromiumExtensionPopup, page: ChromiumPage) {
        popupTrace("host receive \(popup.pointSize) context \(popup.contextID) same \(self.popup === popup) \(traceFrame)")
        guard !popup.closed else { return }
        if self.popup !== popup { pendingPopup = popup; pendingPage = page }
        guard popup.contextID != 0, popup.pointSize.width > 0, popup.pointSize.height > 0 else { return }
        if self.popup !== popup {
            // The native compositor receipt carries Chromium's actual
            // preferred size. Valid narrow layouts are ready too; subsequent
            // native size notifications resize the same original popup.
            // Taken before close() below, which would drop it.
            let held = heldPage === page && heldOver?.extensionID == popup.extensionID ? heldOver : nil
            if held != nil { heldOver = nil; heldPage = nil }
            let list = taken?.id == popup.extensionID ? taken?.popover : held?.popover
            let inList = taken?.id == popup.extensionID || held?.fromDoor == true
            guard let tab = page.navigationTab, let anchor = hang(popup, page: page),
                  let browser = tab.delegate as? Browser, browser.activeID == tab.id,
                  anchor.window === page.window else {
                dropList(); taken = nil; held?.popover.close(); popup.close(); return
            }
            taken = nil
            pendingPopup = nil; pendingPage = nil
            close()
            self.popup = popup; self.page = page; self.anchor = anchor
            pressedAnchor = nil
            followedRect = anchor.window?.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            fromDoor = inList || anchor.id == ChromiumPopupAnchor.sliders
            let content = ChromiumPopupInput(frame: CGRect(origin: .zero, size: popup.pointSize))
            content.popup = popup
            content.wantsLayer = true
            // White behind the page, as on WebKit: a popup that leaves its
            // background unset stands on Chrome's white.
            content.layer?.backgroundColor = NSColor.white.cgColor
            content.layer?.addSublayer(popup.layer)
            content.fit()
            let controller = NSViewController()
            controller.view = content
            controller.preferredContentSize = popup.pointSize
            let popover = list ?? NSPopover()
            popover.delegate = self
            self.popover = popover
            popover.animates = false
            if let list, list.isShown {
                ExtensionPanel.replace(in: list, with: controller)
                list.contentSize = popup.pointSize
            } else {
                popover.contentViewController = controller
                popover.contentSize = popup.pointSize
                popover.behavior = .transient
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            }
            shownExtensionID = popup.extensionID
            // The initial page size can move Chromium's concealed widget
            // back to its bubble anchor after the early .shown event. As
            // with subsequent resizes, restore the producer under the pin
            // once the actual popover has been installed.
            placeProducer(popup, page: page)
            content.window?.makeKey()
            content.window?.makeFirstResponder(content)
            // Consume the dismissing mouse-down before SwiftUI can interpret
            // its mouse-up as another request to open this same extension.
            buttonMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, let anchor = self.anchor, let window = anchor.window,
                          event.window === window,
                          anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) else { return false }
                    self.close()
                    return true
                }
                return consumed ? nil : event
            }
            popupTrace("host shown \(popup.pointSize) anchor \(anchor.window?.convertToScreen(anchor.convert(anchor.bounds, to: nil)) ?? .zero) \(traceFrame)")
            following = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            }
        } else if popover?.contentSize != popup.pointSize {
            popover?.contentViewController?.preferredContentSize = popup.pointSize
            // In this order, as ExtensionPopup.apply: with the view sized
            // first the popover takes its old size back a moment later and
            // the view hangs out of it (seen at 65 x 65 around 350 x 150).
            popover?.contentSize = popup.pointSize
            popover?.contentViewController?.view.setFrameSize(popup.pointSize)
            popupTrace("host resized \(popup.pointSize) \(traceFrame)")
            placeProducer(popup, page: page)
        }
    }

    private func follow() {
        guard let page, let tab = page.navigationTab, !tab.gone,
              let browser = tab.delegate as? Browser, browser.activeID == tab.id,
              page.extensionPopup === popup, let anchor, anchor.window === page.window,
              anchor.usable(in: page.window) else {
            popupTrace("follow lost: active \((page?.navigationTab?.delegate as? Browser)?.activeID == page?.navigationTab?.id) same \(page?.extensionPopup === popup) anchor \(anchor?.window != nil)")
            close(); return
        }
        let rect = anchor.window?.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        if followedRect != rect {
            followedRect = rect
            popover?.positioningRect = anchor.bounds
        }
        if let popup { placeProducer(popup, page: page) }
    }

    func nativeClosed(_ token: String) { if popup?.token == token || pendingPopup?.token == token { close() } }

    /// The extension opened its popup again while it showed (Bitwarden's
    /// chrome.action.openPopup): Chrome closes the shown one for the new one.
    /// Its popover stays up for the newcomer. Closed, it gave Yab's window
    /// key back, the page took focus, and that closed the newcomer too
    /// (lost focus): nothing showed, and it took several presses to open.
    func replace(_ old: ChromiumExtensionPopup, with extensionID: String, page: ChromiumPage) {
        guard popup === old, self.page === page, old.extensionID == extensionID,
              let shown = popover, shown.isShown else { nativeClosed(old.token); return }
        popupTrace("host keeps the popover of \(old.token.prefix(8)) for its replacement")
        let door = fromDoor
        popover = nil
        close()
        heldOver = (shown, extensionID, door); heldPage = page
        shown.delegate = self
    }
    func retire(_ page: ChromiumPage) { if self.page === page || pendingPage === page { close() } }

    func close(from caller: String = #function, line: Int = #line) {
        popupTrace("host close asked by \(caller):\(line) popup \(popup?.token.prefix(8) ?? "none") \(traceFrame)")
        following?.invalidate(); following = nil
        // A held popover goes with the replacement it waited for.
        if let held = heldOver?.popover { heldOver = nil; heldPage = nil; held.delegate = nil; held.close() }
        if let buttonMonitor { NSEvent.removeMonitor(buttonMonitor) }; buttonMonitor = nil
        let old = popup ?? pendingPopup
        pendingPopup = nil; pendingPage = nil
        pressedAnchor = nil; followedRect = nil
        popup = nil; page = nil; anchor = nil
        identityProvider = nil; identityCallerToken = nil
        shownExtensionID = nil
        fromDoor = false
        let popover = popover; self.popover = nil
        popover?.delegate = nil
        popover?.close()
        old?.layer.removeFromSuperlayer()
        old?.close()
    }

    private weak var identityProvider: Tab?
    private var identityCallerToken: String?

    /// Only the exact native identity creation receipt can preserve a caller.
    /// Chrome's action popup stays alive while another browser window is used.
    func preserveIdentityCaller(_ caller: ChromiumPage, provider: Tab) {
        guard page === caller, let popup, caller.extensionPopup === popup, !popup.closed else { return }
        identityProvider = provider
        identityCallerToken = popup.token
    }

    /// The popover's window while a popup is up.
    var popoverWindow: NSWindow? { popover?.contentViewController?.view.window }

    /// Passkey requests of the popup up now: the Mac's sheet takes the focus,
    /// and the popover stays for the answer, as WebKit's does (ExtensionPopup.hold).
    private var passkeyHolds: (token: String, count: Int)?

    func holdForPasskey(_ token: String) -> (() -> Void)? {
        guard let popup, popup.token == token, popover != nil else { return nil }
        passkeyHolds = (token, (passkeyHolds?.token == token ? passkeyHolds?.count ?? 0 : 0) + 1)
        return { [weak self] in
            guard let self, let held = self.passkeyHolds, held.token == token else { return }
            self.passkeyHolds = held.count > 1 ? (token, held.count - 1) : nil
        }
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        popupTrace("popover should close: event \(NSApp.currentEvent?.type.rawValue ?? 0) \(traceFrame)")
        if let popup, passkeyHolds?.token == popup.token { return false }
        if let popup, identityCallerToken == popup.token {
            // AppKit activation notifications are not a user dismissal. The
            // API response can still be on its way when its provider closes.
            if NSApp.currentEvent?.type == .appKitDefined { return false }
            if let provider = identityProvider,
               let window = LinkWindow.all.first(where: { $0.tab === provider })?.window,
               NSApp.keyWindow === window || NSApp.currentEvent?.window === window { return false }
        }
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        popupTrace("popover did close: event \(NSApp.currentEvent?.type.rawValue ?? 0) active \(NSApp.isActive)")
        if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp,
           let popup, let anchor, let window = anchor.window, event.window === window {
            let mouse = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            if anchor.bounds.contains(anchor.convert(mouse, from: nil)) { closedOnButton = (popup.extensionID, Date()) }
        }
        close()
    }

    /// Deliver only to the original current view, as its AppKit mouse path does.
    /// This is not a native IPC acknowledgement; the probe must observe the real product effect.
    func benchPointer(_ input: ChromiumPopupProbeInput, owner: ChromiumPage) -> [String: Any] {
        func refused(_ reason: String, delivered: Int = 0) -> [String: Any] {
            ["eventsDeliveredToOriginalView": delivered, "nativeAcknowledged": false, "refused": reason]
        }
        guard Store.testing, page === owner, let popup, !popup.closed, isShown,
              owner.extensionPopup === popup, let tab = owner.navigationTab, !tab.gone,
              (tab.delegate as? Browser)?.activeID == tab.id,
              let originalPopover = popover,
              let content = originalPopover.contentViewController?.view as? ChromiumPopupInput,
              content.popup === popup, let window = content.window,
              input.matches(token: popup.token, extensionID: popup.extensionID, context: popup.contextID,
                            window: window.windowNumber, size: content.bounds.size) else {
            return refused("original-popup-view-or-lease-unavailable")
        }
        let point = content.convert(CGPoint(x: input.x, y: content.bounds.height - input.y), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else {
            return refused("original-popup-event-unavailable")
        }
        content.mouseDown(with: down)
        guard self.popup === popup, !popup.closed, self.page === owner, isShown,
              owner.extensionPopup === popup, owner.navigationTab === tab, !tab.gone,
              (tab.delegate as? Browser)?.activeID == tab.id,
              self.popover === originalPopover, originalPopover.contentViewController?.view === content,
              content.popup === popup, content.window === window,
              input.matches(token: popup.token, extensionID: popup.extensionID, context: popup.contextID,
                            window: window.windowNumber, size: content.bounds.size) else {
            return refused("original-popup-retired-after-down", delivered: 1)
        }
        content.mouseUp(with: up)
        return ["eventsDeliveredToOriginalView": 2, "nativeAcknowledged": false,
                "forwarding": "original-AppKit-popup-input", "token": popup.token, "context": popup.contextID]
    }

    var state: [String: Any] {
        guard let popup else { return ["shown": false] }
        let rect = popover?.contentViewController?.view.window?.frame ?? .zero
        let from = anchor.flatMap { a in a.window.map { $0.convertToScreen(a.convert(a.bounds, to: nil)) } } ?? .zero
        let content = popover?.contentViewController?.view
        let contentScreen = content.flatMap { view in view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)) } } ?? .zero
        // Popup top-left points relative to the ORIGINAL whole window, matching captured pixels.
        let inset = CGRect(x: contentScreen.minX - rect.minX, y: rect.maxY - contentScreen.maxY,
                           width: contentScreen.width, height: contentScreen.height)
        return ["shown": isShown, "token": popup.token, "extension": popup.extensionID,
                "context": popup.contextID, "size": [popup.pointSize.width, popup.pointSize.height],
                "scale": popup.scale, "screenScale": content?.window?.backingScaleFactor ?? 0,
                "fromDoor": fromDoor,
                "key": content?.window?.isKeyWindow ?? false,
                "firstResponder": content?.window?.firstResponder === content,
                "cursor": popup.cursorShape,
                "frame": [rect.minX, rect.minY, rect.width, rect.height],
                "contentFrameInWindow": [inset.minX, inset.minY, inset.width, inset.height],
                // Global points from the first screen's top left, as a screen capture takes them.
                "contentOnScreen": [contentScreen.minX, (NSScreen.screens.first?.frame.maxY ?? 0) - contentScreen.maxY,
                                    contentScreen.width, contentScreen.height],
                "inputSize": [content?.bounds.width ?? 0, content?.bounds.height ?? 0],
                "anchor": [from.minX, from.minY, from.width, from.height],
                "window": popover?.contentViewController?.view.window?.windowNumber ?? 0]
    }
}

struct ChromiumPopupAnchor: NSViewRepresentable {
    /// The Site Controls door's id here: what a popup without a pin hangs from.
    static let sliders = "site-controls"
    let id: String
    let tab: Tab
    func makeNSView(context: Context) -> View { View(tab: tab, id: id) }
    func updateNSView(_ view: View, context: Context) {
        view.tab = tab
        view.id = id
    }

    @MainActor final class View: NSView {
        weak var tab: Tab?
        var id: String
        private static let all = NSHashTable<View>.weakObjects()
        init(tab: Tab, id: String) { self.tab = tab; self.id = id; super.init(frame: .zero); Self.all.add(self) }
        required init?(coder: NSCoder) { fatalError("not from a nib") }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func usable(in window: NSWindow?) -> Bool {
            guard let host = self.window, window == nil || host === window,
                  !isHiddenOrHasHiddenAncestor, bounds.width > 0, bounds.height > 0,
                  !visibleRect.intersection(bounds).isEmpty else { return false }
            var ancestor: NSView? = self
            while let node = ancestor {
                if node.alphaValue <= 0.01 { return false }
                ancestor = node.superview
            }
            guard let content = host.contentView else { return false }
            return !convert(bounds, to: content).intersection(content.bounds).isEmpty
        }
        /// The ones for this extension showing in `window` now, whatever
        /// their tab, for a window of the extension's own to hang from
        /// (ExtensionWindowFrame).
        static func showing(_ id: String, in window: NSWindow) -> [NSView] {
            all.allObjects.filter { $0.id == id && $0.usable(in: window) }
        }
        /// Every one for this extension, said for a test run's log.
        static func census(_ id: String) -> [String] {
            all.allObjects.filter { $0.id == id }.map { view in
                "chromium window=\(view.window?.windowNumber ?? -1) usable=\(view.usable(in: view.window)) hidden=\(view.isHiddenOrHasHiddenAncestor) bounds=\(view.bounds) visible=\(view.visibleRect)"
            }
        }
        static func find(tab: Tab, id: String, window: NSWindow? = nil,
                         at point: NSPoint = NSEvent.mouseLocation) -> View? {
            // Address-bar and parked plate copies can coexist. Hash-table
            // iteration is not a visual order; resolve the actual press once.
            let candidates = all.allObjects.filter { view in
                view.tab === tab && view.id == id && view.usable(in: window)
            }
            return candidates.min { a, b in
                @MainActor func distance(_ view: View) -> CGFloat {
                    guard let host = view.window else { return .greatestFiniteMagnitude }
                    let rect = host.convertToScreen(view.convert(view.bounds, to: nil))
                    let dx = max(0, max(rect.minX - point.x, point.x - rect.maxX))
                    let dy = max(0, max(rect.minY - point.y, point.y - rect.maxY))
                    return dx * dx + dy * dy
                }
                let da = distance(a), db = distance(b)
                if da != db { return da < db }
                let ra = a.convert(a.bounds, to: nil), rb = b.convert(b.bounds, to: nil)
                if ra.minY != rb.minY { return ra.minY < rb.minY }
                return ra.minX < rb.minX
            }
        }
    }
}

@MainActor
class ChromiumPopupInput: NSView, NSTextInputClient {
    weak var popup: ChromiumExtensionPopup? {
        didSet {
            popup?.onTextInput = { [weak self] in
                popupTrace("popup text input \(String(describing: self?.popup?.textInput)) key \(self?.window?.isKeyWindow ?? false)")
                self?.syncInputContext()
            }
            popup?.onCursor = { [weak self] in self?.applyCursor() }
        }
    }
    /// Like Chromium's view (and a page's, ChromiumPage.inputContext): an input
    /// context only while the focused element takes text or a composition is
    /// open, so no input method works, and no input-mode badge shows, over a
    /// button, a list or a password field.
    private lazy var ownInputContext = NSTextInputContext(client: self)
    private var inputContextActive = false
    private var composes: Bool { popup?.textInput?.editable == true || hasMarkedText() }
    override var inputContext: NSTextInputContext? { composes ? ownInputContext : nil }
    private func syncInputContext(resigning: Bool = false) {
        let active = !resigning && composes && window?.isKeyWindow == true && window?.firstResponder === self
        if active {
            ownInputContext.invalidateCharacterCoordinates()
            if !inputContextActive { ownInputContext.activate() }
        } else if inputContextActive {
            ownInputContext.deactivate()
        }
        inputContextActive = active
    }
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { DispatchQueue.main.async { [weak self] in self?.syncInputContext() } }
        return became
    }
    /// The composition Yab's input method holds for the popup's field; the
    /// popup's view in YabCore only shows it, as for a page (ChromiumPage).
    private var marked = NSAttributedString(string: "")
    private var imeHandled = false
    /// Keys the input method took: their key-ups stay here too.
    private var imeKeys: Set<UInt16> = []
    override var acceptsFirstResponder: Bool { true }

    /// The page's layer fills this view, as Chromium's flipped layer fills its
    /// window (DisplayCALayerTree: width and height sizable). Chromium draws
    /// the page from the top of that layer, and the layer hangs from this
    /// view's bottom (AppKit's layers are not flipped): sized on its own, to
    /// the popup's next size while the popover still had the last one, it
    /// moved the page's top by the difference for a frame, down as the page
    /// shrank and up as it grew, and back once the popover followed. One
    /// jump each time the page changed size (1Password's three as it opens,
    /// #1911). Following this view, it changes with the popover, in one go.
    func fit() {
        guard let popup, popup.layer.superlayer === layer, popup.layer.frame != bounds else { return }
        // No transaction of its own: one committed here could reach the
        // screen before this view's, the old way round.
        popup.layer.frame = bounds
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fit()
    }
    private var tracking: NSTrackingArea?
    private weak var lastPointerMove: NSEvent?
    private lazy var moveTracker = MoveTracker(input: self)
    private final class MoveTracker: NSResponder {
        weak var input: ChromiumPopupInput?
        init(input: ChromiumPopupInput) { self.input = input; super.init() }
        required init?(coder: NSCoder) { nil }
        override func mouseMoved(with event: NSEvent) { input?.moved(event) }
        override func mouseEntered(with event: NSEvent) { input?.moved(event) }
        override func mouseExited(with event: NSEvent) { input?.mouseExited(with: event) }
        override func cursorUpdate(with event: NSEvent) { input?.applyCursor() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: moveTracker)
        addTrackingArea(area); tracking = area
    }
    private func applyCursor() {
        guard let window, window.isKeyWindow, let content = window.contentView,
              bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)),
              let hit = content.hitTest(content.superview?.convert(window.mouseLocationOutsideOfEventStream, from: nil) ?? .zero),
              hit === self || hit.isDescendant(of: self) else { return }
        popup?.cursor.set()
    }
    private func moved(_ event: NSEvent) {
        if lastPointerMove === event { return }
        lastPointerMove = event
        applyCursor(); pointer("mouseMove", event)
    }
    override func mouseMoved(with event: NSEvent) {
        // A first-responder event is a duplicate only if the tracking
        // owner actually delivered that same event.
        moved(event)
    }
    override func mouseExited(with event: NSEvent) { pointer("mouseLeave", event); NSCursor.arrow.set() }
    override func cursorUpdate(with event: NSEvent) { applyCursor() }
    private func pointer(_ kind: String, _ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        popup?.send(["kind": .string(kind), "x": .number(point.x), "y": .number(bounds.height - point.y),
                     "clickCount": .number(Double(ChromiumPage.pointerClickCount(event))), "modifiers": .number(Double(event.modifierFlags.rawValue))])
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // A click ends the composition with what it holds, as Chromium's view does.
        finishComposition()
        pointer("mouseDown", event)
    }
    override func mouseUp(with event: NSEvent) { pointer("mouseUp", event) }
    override func mouseDragged(with event: NSEvent) { pointer("mouseDrag", event) }
    override func rightMouseDown(with event: NSEvent) { finishComposition(); pointer("rightDown", event) }
    override func rightMouseUp(with event: NSEvent) { pointer("rightUp", event) }
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The scroll's own event, as a page's (ChromiumWheelInput). Its phases
        // went over as NSEvent's bits, which are not CGEvent's, and a notch's
        // lines as points.
        var fields = ChromiumWheelInput.fields(event, at: NSPoint(x: point.x, y: bounds.height - point.y))
        fields["kind"] = .string("wheel")
        popup?.send(fields)
    }
    override func keyDown(with event: NSEvent) {
        // Escape while composing is the input method's (it cancels the
        // composition); otherwise it closes the popup, as in Chromium.
        if event.keyCode == 53, !hasMarkedText() { ChromiumPopupHost.shared.close(); return }
        // The popover's window may have become key after the field's state
        // came: the input method answers only its active context.
        if composes, !inputContextActive { syncInputContext() }
        if composeKey(event) { return }
        // An editing key the menu didn't take (its row moved or is gone):
        // the same command as the menu's, never a raw ⌘ key, which the
        // popup's renderer on a Mac reads as no command at all.
        if let command = ChromiumPopupEdit.command(for: event) { edit(command); return }
        key("keyDown", event)
    }

    /// Plain typing and composition follow the same rule as a page's, using
    /// the popup's field state from YabCore.
    private func composeKey(_ event: NSEvent) -> Bool {
        let editable = popup?.textInput?.editable == true
        guard ChromiumPage.usesInputContext(event, marked: hasMarkedText(), editable: editable),
              let context = inputContext else { return false }
        // AppKit makes the key window's first responder's context current
        // when the window becomes key; ours may have been nil then.
        if NSTextInputContext.current !== context { context.activate(); inputContextActive = true }
        imeHandled = false
        let taken = context.handleEvent(event)
        popupTrace("popup ime key \(event.keyCode) source \(context.selectedKeyboardInputSource ?? "-") current \(NSTextInputContext.current === context) taken \(taken) handled \(imeHandled) marked \(marked.string)")
        if imeHandled { imeKeys.insert(event.keyCode) }
        return imeHandled
    }

    private func finishComposition() {
        guard hasMarkedText() else { return }
        let context = inputContext
        marked = NSAttributedString(string: "")
        context?.discardMarkedText()
        popup?.send(["kind": .string("unmark")])
        syncInputContext()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { finishComposition(); imeKeys.removeAll(); syncInputContext(resigning: true) }
        return resigned
    }

    /// Edit's menu rows land here as the popup's first responder. Chrome's
    /// own Edit menu sends these to the popup's view; the helper that draws
    /// it has no menu, so the command goes to that view through the helper.
    @objc func paste(_ sender: Any?) { edit(.paste) }
    @objc func pasteAsPlainText(_ sender: Any?) { edit(.pasteAndMatchStyle) }
    @objc func copy(_ sender: Any?) { edit(.copy) }
    @objc func cut(_ sender: Any?) { edit(.cut) }
    @objc override func selectAll(_ sender: Any?) { edit(.selectAll) }
    @objc func undo(_ sender: Any?) { edit(.undo) }
    @objc func redo(_ sender: Any?) { edit(.redo) }
    private func edit(_ command: ChromiumPopupEdit) {
        popupTrace("popup edit \(command.rawValue)")
        finishComposition()
        popup?.send(["kind": .string("edit"), "command": .string(command.rawValue)])
    }
    override func keyUp(with event: NSEvent) {
        if imeKeys.remove(event.keyCode) != nil { return }
        key("keyUp", event)
    }
    override func flagsChanged(with event: NSEvent) { key("flagsChanged", event) }
    private func key(_ kind: String, _ event: NSEvent) {
        var fields = ChromiumKeyboardInput.fields(event)
        fields["kind"] = .string(kind)
        popup?.send(fields)
    }

    // NSTextInputClient: what the input method composes and commits goes to
    // the popup's own view in YabCore (popup.input "compose", "text",
    // "unmark"), which shows the composition as Chromium's does.
    override func insertText(_ string: Any) {
        insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        imeHandled = true
        popupTrace("popup ime insert \(text.count) chars")
        let composed = marked.length > 0
        marked = NSAttributedString(string: "")
        popup?.send(["kind": .string("text"), "text": .string(text)])
        if composed { syncInputContext() }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        imeHandled = true
        popupTrace("popup ime mark \(marked.length) units")
        let start = selectedRange.location == NSNotFound ? marked.length : selectedRange.location
        let length = selectedRange.location == NSNotFound ? 0 : selectedRange.length
        popup?.send(["kind": .string("compose"), "text": .string(marked.string),
                     "selectionStart": .number(Double(start)), "selectionLength": .number(Double(length))])
    }
    func unmarkText() {
        guard marked.length > 0 else { return }
        marked = NSAttributedString(string: "")
        popup?.send(["kind": .string("unmark")])
        syncInputContext()
    }
    /// Positions inside the composition; with none, an empty selection at
    /// its start rather than none at all, which input methods read as a
    /// client that takes no text.
    func selectedRange() -> NSRange {
        NSRange(location: marked.length, length: 0)
    }
    func markedRange() -> NSRange {
        marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let whole = NSRange(location: 0, length: marked.length)
        let part = NSIntersectionRange(whole, range)
        guard range.location != NSNotFound, part.length > 0 || range.length == 0 else { return nil }
        actualRange?.pointee = part
        return marked.attributedSubstring(from: part)
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    /// The candidate window hangs under the field's caret, as YabCore last
    /// reported it; with none yet, under the popup's top left.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let caret = popup?.textInput?.caret ?? CGRect(x: 8, y: 8, width: 1, height: 18)
        let local = NSRect(x: caret.minX, y: bounds.height - caret.maxY, width: max(1, caret.width), height: caret.height)
        return window.convertToScreen(convert(local, to: nil))
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    override func doCommand(by selector: Selector) {}
}
