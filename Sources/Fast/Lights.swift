import AppKit
import Combine
import SwiftUI

// The traffic lights, as a piece of the layout rather than of the title bar.
//
// They used to be the title bar's own three, pushed down by hand into the
// strip every time AppKit laid its title bar out again, a resize, full
// screen, the window becoming key, with a painted set of gray circles over
// them while the app was behind. That fought AppKit on every pass (it once
// caught the row halfway through a resize and closed it up to 13 points),
// and it pinned the lights to the window's corner: the column could slide
// away into the left edge and they stayed floating where it had been.
//
// Now the title bar's own are hidden and the window gets a fresh three from
// NSWindow.standardWindowButton(_:for:), the public way to have the real
// thing somewhere else. They close, minimize and zoom the window they are in,
// draw their own resting state, and sit wherever the view holding them sits:
// in the column's corner, at the head of the strip, in the band a shut
// column leaves. Where the column goes, they go.
//
// The green one's menu under a resting pointer, Move & Resize, Fill &
// Arrange, Full Screen and the other screens, is AppKit's too, drawn by a
// service of macOS's over the button wherever it stands, and asks the
// window what it may do: the moving and arranging are in it only for a
// window macOS may move (WindowDrag). A fresh button shows it as the title
// bar's own does (evals/window-tiling/lab, 2026-10-07).

/// The three buttons, closest one's center `Lights.lead` in from the leading
/// edge and all three centered in the height they are given.
struct Lights: NSViewRepresentable {
    /// From the leading edge to the close button's center.
    static let lead: CGFloat = 7
    /// From the window's edge to the close button's center wherever the
    /// window's own lights stand, strip or column: Arc's 20 (measured
    /// against Arc on 2026-10-21, its 19.7).
    static let first: CGFloat = 20
    /// Three buttons and the two gaps between them, on the widest spacing any
    /// macOS has used.
    static let run: CGFloat = 60

    /// The air around the three moves the window from a strip of the row's
    /// own, for a place where no DragStrip may stand under them (SideBar's
    /// band).
    var handle = false

    func makeNSView(context: Context) -> LightsRow { LightsRow() }
    func updateNSView(_ view: LightsRow, context: Context) { view.handle = handle }
}

/// Local hit geometry is cheap; asking which window is above it is a
/// synchronous WindowServer trip. Only a possible hit needs that answer.
enum LightsPointerProbe {
    enum Hit: Equatable {
        case outsideBounds, outsideVisibleRect, covered(Int), inside
    }

    static func hit(_ point: NSPoint, bounds: NSRect, visibleRect: NSRect? = nil,
                    ownWindow: Int, topWindow: () -> Int,
                    seeThrough: (Int) -> Bool = { _ in false }) -> Hit {
        guard bounds.contains(point) else { return .outsideBounds }
        guard visibleRect?.contains(point) ?? true else { return .outsideVisibleRect }
        let top = topWindow()
        return top == ownWindow || seeThrough(top) ? .inside : .covered(top)
    }
}

final class LightsRow: NSView {
    /// Every row in a window, for the views around them to keep clear of.
    private static let live = NSHashTable<LightsRow>.weakObjects()

    /// Lights.handle: a strip in the row, under the buttons, so to
    /// SwiftUI's accessibility hit test the row is the one view there.
    var handle = false {
        didSet {
            guard handle != oldValue else { return }
            strip?.removeFromSuperview()
            strip = nil
            guard handle else { return }
            let made = DragStrip.Strip(frame: bounds)
            made.autoresizingMask = [.width, .height]
            made.isHidden = buttons.first?.isHidden ?? false
            addSubview(made, positioned: .below, relativeTo: nil)
            strip = made
        }
    }
    private var strip: DragStrip.Strip?

    /// The button of a row shown in `window` under `point`, in `view`'s own
    /// coordinates: a window's drag strip hands a press there to the light
    /// (DragStrip), whichever view SwiftUI's hit test chose.
    static func button(at point: NSPoint, from view: NSView, in window: NSWindow) -> NSButton? {
        let at = view.convert(point, to: nil)
        for row in live.allObjects where row.window === window && !row.isHiddenOrHasHiddenAncestor && row.alphaValue > 0 {
            for button in row.buttons where !button.isHidden && button.isEnabled
                && button.convert(button.bounds, to: nil).contains(at) {
                return button
            }
        }
        return nil
    }

    private var buttons: [NSButton] = []

    /// The green light of a row shown in `window`, pressed by the bench
    /// as a click would press it, with no pointer.
    static func zoomButton(in window: NSWindow) -> NSButton? {
        live.allObjects.first { $0.window === window && $0.buttons.count == 3 }?.buttons[2]
    }
    /// AppKit's spacing, read off the title bar's own buttons while they are
    /// still where AppKit put them.
    private var spacing: CGFloat = 20
    /// The pointer is over one of the three, so all three show their marks,
    /// asked for by the buttons themselves through _mouseInGroup:, the way
    /// the title bar answers them.
    private var inside = false {
        didSet { if inside != oldValue { tell() } }
    }
    /// How many times the buttons have asked, for the tests.
    private(set) var asked = 0
    private var watching: [NSObjectProtocol] = []
    private var pointer: Any?
    private var hover: DispatchWorkItem?
    private var hoverFrame: NSRect?
    private var hoverAsked = false
    private var hoverTurn = 0
    private var menus: Set<ObjectIdentifier> = []
    private var hoverTrace: [String] = []
    private var hoverResult = "unasked"
    private var hoverArmed = 0
    private var hoverFired = 0
    private var hoverCancel = "none"

    deinit {
        hover?.cancel()
        if let pointer { NSEvent.removeMonitor(pointer) }
        watching.forEach(NotificationCenter.default.removeObserver)
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cancelHover("attach")
        if let pointer { NSEvent.removeMonitor(pointer) }
        pointer = nil
        menus = []
        watching.forEach(NotificationCenter.default.removeObserver)
        watching = []
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        guard let window else { return }

        LightsRow.live.add(self)
        Lights.hideOwn(of: window)
        let own = Lights.own(of: window)
        let measured = own.count == 3 ? own[1].frame.minX - own[0].frame.minX : 0
        spacing = (16...32).contains(measured) ? measured : 20

        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = NSWindow.standardWindowButton(type, for: window.styleMask) else { continue }
            addSubview(button)
            buttons.append(button)
        }
        needsLayout = true
        refresh()

        // Key or not, active or not, full screen or not: the buttons in a
        // title bar are told about each of these by AppKit, and these are not
        // in a title bar.
        let center = NotificationCenter.default
        let names: [(NSNotification.Name, AnyObject?)] = [
            (NSWindow.didBecomeKeyNotification, window), (NSWindow.didResignKeyNotification, window),
            (NSWindow.didBecomeMainNotification, window), (NSWindow.didResignMainNotification, window),
            (NSWindow.didDeminiaturizeNotification, window),
            (NSWindow.didEnterFullScreenNotification, window), (NSWindow.didExitFullScreenNotification, window),
            (NSApplication.didBecomeActiveNotification, NSApp), (NSApplication.didResignActiveNotification, NSApp),
        ]
        for (name, object) in names {
            watching.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                AppKitMainThread.sync { self?.cancelHover(name.rawValue); self?.refresh() }
            })
        }
        // Moved or resized: posted on every frame of a drag, and `refresh`
        // asks the window server what is under the pointer, a round trip
        // each time (about 3 ms a frame of a live resize, a third of the
        // main thread's time then). Looked at once the window is at rest.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            watching.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                AppKitMainThread.sync {
                    self?.cancelHover(name.rawValue)
                    self?.refreshAtRest(now: name == NSWindow.didEndLiveResizeNotification)
                }
            })
        }
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification,
                     NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            watching.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                AppKitMainThread.sync { self?.cancelHover(name.rawValue) }
            })
        }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            watching.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                AppKitMainThread.sync {
                    guard let self, let menu = note.object as? NSMenu else { return }
                    if note.name == NSMenu.didBeginTrackingNotification {
                        self.menus.insert(ObjectIdentifier(menu))
                        self.noteHover("menu began \(ObjectIdentifier(menu))")
                        self.hoverAsked = true
                        self.cancelPendingHover()
                    } else {
                        self.menus.remove(ObjectIdentifier(menu))
                        self.noteHover("menu ended \(ObjectIdentifier(menu))")
                    }
                }
            })
        }
        // Hosting views can consume the row's own tracking events while
        // AppKit still sends mouseEntered to the button's cell. Follow the
        // real events before dispatch, without changing or swallowing them.
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .mouseEntered, .mouseExited,
                                           .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .keyDown]
        pointer = NSEvent.addLocalMonitorForEvents(matching: kinds) { [weak self] event in
            AppKitMainThread.sync {
                guard let self else { return }
                if event.window === self.window,
                   [.mouseMoved, .mouseEntered, .mouseExited].contains(event.type) {
                    self.inside = self.pointerOver()
                    self.trackHover()
                } else {
                    self.cancelHover("event \(event.type.rawValue) window=\(event.window?.windowNumber ?? 0)")
                }
            }
            return event
        }
    }

    private var atRest: DispatchWorkItem?

    private func refreshAtRest(now: Bool) {
        atRest?.cancel()
        atRest = nil
        guard !now, let window else { return refresh() }
        let work = DispatchWorkItem { [weak self] in
            AppKitMainThread.sync {
                self?.atRest = nil
                self?.refresh()
            }
        }
        atRest = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (window.inLiveResize ? 0.25 : 0.1), execute: work)
    }

    private func refresh() {
        guard let window else { return }
        // In full screen there is no minimizing, closing and leaving are
        // still there, the same as the title bar macOS shows there.
        let full = window.styleMask.contains(.fullScreen)
        for (index, button) in buttons.enumerated() {
            if index == 1 { button.isEnabled = !full }
        }
        var ancestor = superview
        while let view = ancestor {
            if let column = view as? ColumnView { columnVisibilityChanged(column.shown); return }
            ancestor = view.superview
        }
        columnVisibilityChanged(true)
    }

    /// A column moves its drawing with a layer transform, leaving AppKit's
    /// tracking areas in their old geometry. Its native buttons must stop
    /// tracking too, or the hidden green can open its menu over the page.
    func columnVisibilityChanged(_ shown: Bool) {
        // An overlay in another app's full-screen Space has no green light.
        for (index, button) in buttons.enumerated() {
            button.isHidden = !shown || (index == 2 && window is LinkWindow.FullScreenFrame)
        }
        // The row's own strip goes with them: the row takes nothing in the
        // column's old place.
        strip?.isHidden = !shown
        // Where the pointer is now, not where it was: a window coming back
        // from the Dock left with it over the minimize button, and one made
        // key under a resting pointer has it there with no move to say so.
        inside = shown && pointerOver()
        tell()
        if shown { trackHover() } else { cancelHover("column hidden") }
    }

    /// The buttons told to look again, as the title bar tells its own when
    /// the pointer comes onto them or leaves (NSThemeFrame sends each one
    /// mouseEnteredOrExited). A button keeps the look it worked out last,
    /// key or not, marks or not, and only asks _mouseInGroup: again when
    /// told: drawn again with needsDisplay alone, it drew that same look. So
    /// the close and minimize buttons never showed their marks (feedback #64),
    /// and the zoom button did only when its own area for the tiling menu
    /// had it look again after the row knew the pointer was there.
    private func tell() {
        let told = NSSelectorFromString("mouseEnteredOrExited")
        for button in buttons {
            if button.responds(to: told) { _ = button.perform(told) }
            button.needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        var moved = false
        for (index, button) in buttons.enumerated() {
            let size = button.frame.size
            let origin = NSPoint(
                x: Lights.lead - size.width / 2 + CGFloat(index) * spacing,
                y: ((bounds.height - size.height) / 2).rounded()
            )
            guard button.frame.origin != origin else { continue }
            button.setFrameOrigin(origin)
            moved = true
        }
        // Moved under a pointer at rest, which sends no move to say so.
        if moved {
            inside = pointerOver()
            cancelHover("layout")
            trackHover()
        }
    }

    // MARK: - the pointer

    /// The three and the gaps between them, where the pointer shows all
    /// three marks.
    private var group: NSRect {
        guard let first = buttons.first, let last = buttons.last else { return .zero }
        return first.frame.union(last.frame)
    }

    /// The whole row, whatever its size, wherever layout has put the buttons
    /// in it: an area of the buttons' own frames was taken before the first
    /// layout had moved them there, and the marks came only over the zoom
    /// button, from its own area for the tiling menu, or not at all.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { follow(event) }
    override func mouseMoved(with event: NSEvent) { follow(event) }
    override func mouseExited(with event: NSEvent) { inside = false; trackHover() }

    private func follow(_ event: NSEvent) {
        inside = group.contains(convert(event.locationInWindow, from: nil))
        trackHover()
    }

    /// The pointer onto the actual green button starts the button's own
    /// hover, as a title bar's does: its cell hears the pointer come onto
    /// it but never starts the timer itself outside a title bar. Started,
    /// AppKit waits its own dwell, shows the menu from its service, out of
    /// this process, and takes it down again: the app keeps going under
    /// the menu and a click on the button goes full screen at once.
    ///
    /// It used to be a timer of ours that asked for the menu through
    /// Accessibility (accessibilityPerformShowMenu), which waits in here
    /// until the menu is gone: Yab stood still under the menu, the window
    /// stopped being key, and clicks on the button went to taking the menu
    /// down, several before one went full screen (register #375). That way
    /// stays only for a cell without the hover of its own.
    private func trackHover() {
        guard let button = buttons.last else { cancelHover("no green"); return }
        let under = greenProbe(button)
        guard let frame = under.frame else { cancelHover(under.why); return }
        if hoverFrame == frame { return }
        cancelHover("new entry")
        hoverFrame = frame
        guard menus.isEmpty else { hoverAsked = true; noteHover("blocked by menus \(menus)"); return }
        let start = NSSelectorFromString("startTrackingHover")
        if let cell = button.cell, cell.responds(to: start) {
            hoverAsked = true
            hoverArmed += 1
            _ = cell.perform(start)
            hoverResult = "native"
            noteHover("cell startTrackingHover")
            return
        }
        let turn = hoverTurn
        hoverArmed += 1
        noteHover("armed turn=\(turn) frame=\(frame)")
        let work = DispatchWorkItem { [weak self, weak button] in
            AppKitMainThread.sync {
                guard let self else { return }
                self.hoverFired += 1
                self.noteHover("fired turn=\(turn) current=\(self.hoverTurn)")
                guard let button, self.hoverTurn == turn,
                      self.buttons.last === button, self.hoverFrame == frame,
                      !self.hoverAsked, self.menus.isEmpty else {
                    self.noteHover("fire stale/asked/menu")
                    return
                }
                let under = self.greenProbe(button)
                guard under.frame == frame else { self.noteHover("fire blocked \(under.why)"); return }
                self.hover = nil
                self.hoverAsked = true
                // An automatic AppKit popup already there must stay there.
                guard !self.nativeMenuNear(button) else { self.noteHover("native menu already near"); return }
                // This standard control exposes its cell to Accessibility;
                // NSButton's inherited action returns false without a menu.
                let result = button.cell?.accessibilityPerformShowMenu() ?? false
                self.hoverResult = String(result)
                self.noteHover("cell show-menu returned \(result)")
            }
        }
        hover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func cancelPendingHover() {
        hoverTurn += 1
        hover?.cancel()
        hover = nil
    }

    private func cancelHover(_ reason: String = "cancel") {
        hoverCancel = reason
        if hoverFrame != nil || hover != nil { noteHover("cancel \(reason)") }
        cancelPendingHover()
        hoverFrame = nil
        hoverAsked = false
    }

    private func noteHover(_ line: String) {
        guard Store.testing else { return }
        hoverTrace.append(String(format: "%.2f ", CACurrentMediaTime()) + line)
        if hoverTrace.count > 40 { hoverTrace.removeFirst(hoverTrace.count - 40) }
    }

    private func greenProbe(_ button: NSButton) -> (frame: NSRect?, why: String) {
        guard let window else { return (nil, "no window") }
        guard button.window === window else { return (nil, "button window") }
        guard window.isVisible, !window.isMiniaturized else { return (nil, "window invisible/minimized") }
        guard window.isKeyWindow, NSApp.isActive else { return (nil, "window inactive/nonkey") }
        guard NSApp.modalWindow == nil, window.attachedSheet == nil else { return (nil, "modal/sheet") }
        guard button.isEnabled, !button.isHiddenOrHasHiddenAncestor else { return (nil, "button disabled/hidden") }
        guard NSEvent.pressedMouseButtons == 0 else { return (nil, "mouse pressed \(NSEvent.pressedMouseButtons)") }
        let screen = NSEvent.mouseLocation
        let at = window.convertPoint(fromScreen: screen)
        let local = button.convert(at, from: nil)
        switch LightsPointerProbe.hit(local, bounds: button.bounds, visibleRect: button.visibleRect,
            ownWindow: window.windowNumber,
            topWindow: { NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) },
            seeThrough: Self.seeThrough) {
        case .outsideBounds: return (nil, "outside bounds \(local)")
        case .outsideVisibleRect: return (nil, "outside visible \(button.visibleRect) point \(local)")
        case .covered(let top): return (nil, "top window \(top) own \(window.windowNumber)")
        case .inside: break
        }
        let hit = window.contentView?.superview?.hitTest(at)
        guard hit === button else { return (nil, "root hit \(hit.map { String(describing: type(of: $0)) } ?? "nil")") }
        return (window.convertToScreen(button.convert(button.bounds, to: nil)), "ready")
    }

    /// A window over the button that hides nothing: one fully see-through,
    /// or the green menu's own service, whose window can stay on screen
    /// after its menu has gone. The pointer still reaches the button.
    private static func seeThrough(_ number: Int) -> Bool {
        guard number > 0, let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
              let row = rows.first else { return false }
        let alpha = (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        return alpha <= 0 || row[kCGWindowOwnerName as String] as? String == "ThemeWidgetControlViewService"
    }

    /// AppKit can draw this menu in a separate service instead of an NSMenu
    /// tracking notification. Only its visible popup beside this green counts.
    private func nativeMenuNear(_ button: NSButton) -> Bool {
        guard let window else { return false }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let point = CGPoint(x: rect.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.midY)
        let listed = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return listed.contains { row in
            guard row[kCGWindowOwnerName as String] as? String == "ThemeWidgetControlViewService",
                  ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let box = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: box as CFDictionary), frame.width > 0, frame.height > 0 else { return false }
            return frame.insetBy(dx: -70, dy: -70).contains(point)
        }
    }

    /// The pointer over the three, read off the screen, in this window and
    /// not one in front of it.
    private func pointerOver() -> Bool {
        guard let window, !buttons.isEmpty, !isHiddenOrHasHiddenAncestor else { return false }
        let screen = NSEvent.mouseLocation
        let local = convert(window.convertPoint(fromScreen: screen), from: nil)
        return LightsPointerProbe.hit(local, bounds: group, ownWindow: window.windowNumber,
            topWindow: { NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) }) == .inside
    }

    @objc func _mouseInGroup(_ button: NSButton) -> Bool {
        asked += 1
        return inside
    }

    /// Only the buttons take clicks; the air around them is title bar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// For the bench: the green button, the areas AppKit hears the pointer
    /// come onto it by, and whether the pointer is over the three, all from
    /// the window's top left.
    var green: [String: Any] {
        guard let window, let zoom = buttons.last, let frame = window.contentView?.superview else { return [:] }
        func flip(_ r: NSRect) -> [Int] {
            // Bench.whole: a button caught mid-layout can be NaN, and Int() traps (#381).
            [r.minX, window.frame.height - r.maxY, r.width, r.height].map(Bench.whole)
        }
        let areas = frame.trackingAreas.filter { $0.owner === zoom.cell }.map { flip(frame.convert($0.rect, to: nil)) }
        let under = greenProbe(zoom)
        let target = NSAccessibility.unignoredDescendant(of: zoom) as AnyObject?
        let action = NSSelectorFromString("accessibilityPerformShowMenu")
        let accessibility: [String: Any] = [
            "target": target.map { String(describing: type(of: $0)) } ?? "nil",
            "button": target === zoom, "cell": target === zoom.cell,
            "buttonElement": zoom.isAccessibilityElement(), "cellElement": zoom.cell?.isAccessibilityElement() ?? false,
            "buttonAllows": zoom.isAccessibilitySelectorAllowed(action),
            "cellAllows": zoom.cell?.isAccessibilitySelectorAllowed(action) ?? false,
        ]
        let hover: [String: Any] = ["pending": self.hover != nil, "asked": hoverAsked, "turn": hoverTurn,
                                   "menus": menus.map { String(describing: $0) }.sorted(), "guard": under.why,
                                   "action": hoverResult, "armed": hoverArmed, "fired": hoverFired,
                                   "cancel": hoverCancel, "trace": hoverTrace]
        return ["button": flip(zoom.convert(zoom.bounds, to: nil)), "areas": areas, "enabled": zoom.isEnabled,
                "hidden": zoom.isHiddenOrHasHiddenAncestor, "inside": inside, "cell": zoom.cell.map { "\(type(of: $0))" } ?? "", "hover": hover,
                "accessibility": accessibility]
    }

    /// For the bench: each button's leading edge and its center's height,
    /// from the window's top-left.
    var spots: [[Int]] {
        guard let window else { return [] }
        return buttons.map { button in
            let frame = button.convert(button.bounds, to: nil)
            return [frame.minX, window.frame.height - frame.midY].map(Bench.whole)
        }
    }
}

extension Lights {
    /// The title bar's own three stay out of sight in a window, whatever
    /// AppKit does to the title bar: it puts them back on show when it
    /// rebuilds it for full screen and on the way out of it.
    @MainActor
    static func hideOwn(of window: NSWindow) {
        showOwn(false, of: window)
    }

    /// In full screen the title bar's own three are the lights, in the band
    /// macOS brings down with its menu bar, and ours are gone.
    @MainActor
    static func showOwn(_ shown: Bool, of window: NSWindow) {
        own(of: window).forEach { $0.isHidden = !shown }
    }

    /// The title bar's own three, as the window has them now. Asked while
    /// ours are in it, standardWindowButton(_:) is as likely to answer with
    /// one of ours, from wherever it sits in the window, so the three last
    /// found stand in then. Asked afresh each time, not kept from the first
    /// look: AppKit builds the title bar's buttons again (full screen, a
    /// window's style settling as it opens), and a window opened where a
    /// closed one stood in memory has its address. Kept by the address, the
    /// three were the closed window's or ones AppKit had let go, nothing put
    /// the new ones away, and they showed beside ours (feedback #168).
    @MainActor
    static func own(of window: NSWindow) -> [NSButton] {
        let key = ObjectIdentifier(window)
        let found = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .filter { !($0.superview is LightsRow) }
        if found.count == 3 {
            titleBars[key] = Held(window: window, buttons: found)
            return found
        }
        guard let held = titleBars[key], held.window === window else { return [] }
        let kept = held.buttons.compactMap(\.button)
        return kept.count == 3 ? kept : []
    }

    /// The title bar itself, the view AppKit slides down under the menu bar
    /// in full screen. Found from its own buttons, which sit inside it.
    @MainActor
    static func titleBar(of window: NSWindow) -> NSView? {
        var view = own(of: window).first?.superview
        while let found = view, !String(describing: type(of: found)).contains("TitlebarContainer") {
            view = found.superview
        }
        return view
    }

    /// The title bar, shown. In full screen it is the band macOS brings
    /// down with its menu bar, with its own three lights in it.
    @MainActor
    static func showTitleBar(_ shown: Bool, of window: NSWindow) {
        guard let bar = titleBar(of: window) else { return }
        bar.isHidden = !shown
        bar.alphaValue = shown ? 1 : 0
    }

    /// How tall that band is, for what has to step down under it.
    @MainActor
    static func titleBarHeight(of window: NSWindow) -> CGFloat {
        let height = own(of: window).first?.superview?.frame.height ?? 0
        return (20...60).contains(height) ? height : 28
    }

    private final class Weak {
        weak var button: NSButton?
        init(_ button: NSButton) { self.button = button }
    }
    private final class Held {
        weak var window: NSWindow?
        let buttons: [Weak]
        init(window: NSWindow, buttons: [NSButton]) {
            self.window = window
            self.buttons = buttons.map(Weak.init)
        }
    }
    @MainActor private static var titleBars: [ObjectIdentifier: Held] = [:]

    /// A closed secondary window drops its cached title bar buttons.
    @MainActor
    static func forgetTitleBar(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        if let held = titleBars[key], held.window == nil || held.window === window {
            titleBars[key] = nil
        }
    }

    /// The rows in a window, for the bench.
    @MainActor
    static func rows(in view: NSView?) -> [LightsRow] {
        guard let view else { return [] }
        if let row = view as? LightsRow { return [row] }
        return view.subviews.flatMap(rows(in:))
    }
}

// MARK: - the left edge

/// Where the pointer stands against the window's left edge while the column
/// is put away, from the window's top left: x in from its left edge, less
/// than 0 past it, y down from its top.
///
/// The put-away column comes out after a short rest within its edge zone,
/// wherever the pointer came from (register 1403).
/// The edge is a wall only where the screen ends: a window inset from the
/// screen's edge, as a new one is on a laptop, has a line two points wide
/// there, and a hand on its way to it runs past. So going out past the
/// edge, between two looks or in one, is reaching it; and while the column
/// is out, a hand anywhere past it beside the window, or up to a little way
/// off the card's other side, is still with the card, as with Dia's.
enum EdgeReach {
    static func inside(_ point: CGPoint, height: CGFloat) -> Bool {
        point.x >= 0 && point.y >= 0 && point.y <= height
    }

    /// Whether the pointer is looked at for a window. Always for the one in
    /// front. For one behind another app's, only while the pointer is over
    /// it with nothing covering it there: `top` is the number of the
    /// topmost window under the pointer and `own` the window's number and
    /// its child windows'. Both are asked only once the pointer is inside
    /// the window's frame, so a window behind costs the window server
    /// nothing while the pointer is elsewhere.
    static func watches(front: Bool, onScreen: Bool, frame: CGRect, pointer: CGPoint,
                        top: @autoclosure () -> Int, own: @autoclosure () -> Set<Int>) -> Bool {
        if front { return true }
        guard onScreen, frame.contains(pointer) else { return false }
        return own().contains(top())
    }

    /// The pointer reached the left edge: on it, or gone out past it since
    /// the last look, through the edge itself and not over the top or the
    /// bottom. Coming in from outside is not reaching it.
    static func wall(_ point: CGPoint, last: CGPoint?, height: CGFloat) -> Bool {
        if inside(point, height: height) { return point.x <= Metrics.edgeWall }
        guard point.x < 0, let last, inside(last, height: height) else { return false }
        // Where the move from the last look crossed the edge's line.
        let t = last.x / (last.x - point.x)
        let y = last.y + (point.y - last.y) * t
        return y >= 0 && y <= height
    }

    /// Only the outermost points belong to the hidden column. Page logos
    /// and menus just inside the window must receive their own hover.
    static let hoverReach: CGFloat = 3

    /// The pointer is near the edge, where resting brings the column out,
    /// or out past it beside the window, having gone out
    /// through it (`past`, kept by Brim from look to look).
    static func at(_ point: CGPoint, past: Bool, height: CGFloat) -> Bool {
        if inside(point, height: height) { return point.x <= hoverReach }
        return past && point.x < 0 && point.y >= 0 && point.y <= height
    }

    /// The pointer is out past the edge over another window: one tiled
    /// beside this window, another app's or another of Yab's (#1024). That
    /// is not the edge, and a rest there brings nothing. Empty desktop out
    /// there still is: no window under the pointer (`top` 0), or one that
    /// is not an app's ordinary window, the desktop's own. `top` is the
    /// number of the topmost window under the pointer and `own` the
    /// window's number and its child windows'.
    static func covered(top: Int, own: Set<Int>, ordinary: (Int) -> Bool) -> Bool {
        top != 0 && !own.contains(top) && ordinary(top)
    }

    /// The pointer has left the window for another display: outside the
    /// window and off the screen the window is on, in screen space (a tester's
    /// report, 2026-10-13). With a display arranged beside the window's
    /// edge, going out past the edge is going over to that display, not
    /// reaching the edge: it brings nothing, and lets a card go. Out past
    /// the edge still on the window's own screen, a window inset from its
    /// edge, stays the edge's (`at`, `keeps`). Nil `screen`, the window off
    /// every screen, takes nothing as away.
    static func away(_ pointer: CGPoint, window: CGRect, screen: CGRect?) -> Bool {
        func holds(_ r: CGRect) -> Bool {
            pointer.x >= r.minX && pointer.x <= r.maxX && pointer.y >= r.minY && pointer.y <= r.maxY
        }
        guard let screen else { return false }
        return !holds(window) && !holds(screen)
    }

    /// The pointer keeps a column brought out as a card: over it, or within
    /// `reach` of the window's left edge, as a hand drifting off the card's
    /// other side may go, or anywhere past that edge beside the window, as
    /// Dia keeps its card with the pointer 200 points out there. In full
    /// screen the edge is the screen's, and there is no top or bottom to it.
    static func keeps(_ point: CGPoint, reach: CGFloat, height: CGFloat, full: Bool) -> Bool {
        guard point.x <= reach else { return false }
        if full { return true }
        return point.y >= 0 && point.y <= height
    }

    /// Only the side edge reveals the column. The lights become accessible
    /// with it; their old corner target overlaps the page's own controls.
    static func rest(edge: Bool) -> CFTimeInterval? {
        edge ? edgeRest : nil
    }

    /// A pass through the edge brings nothing; a rest does, from either side.
    static let edgeRest: CFTimeInterval = 0.3
    static let cornerRest: CFTimeInterval = 0.35

    /// The rest's deadline, read with the same clock as the pointer's look.
    /// Leaving the target forgets it; a different target starts its own rest.
    struct Dwell {
        private(set) var until: CFTimeInterval?
        private var rest: CFTimeInterval?

        mutating func remaining(rest: CFTimeInterval?, now: CFTimeInterval) -> CFTimeInterval? {
            guard let rest else {
                self = Self()
                return nil
            }
            if self.rest != rest {
                self.rest = rest
                until = now + rest
            }
            return max(0, (until ?? now) - now)
        }
    }

    /// How long the corner keeps quiet after a press in it.
    static let pressQuiet: CFTimeInterval = 1.5
    /// How long the card waits once the pointer has left it, before it
    /// goes: Dia's starts going 0.1 s after (0.10 to 0.13 s, its first
    /// frame on the way out, measured from the move off the card).
    static let letGo: CFTimeInterval = 0.08
    /// The sidebar starts leaving as the pointer leaves its safe area.
    /// The three Dia takes on the physical Retina display (2026-10-22)
    /// start in 40–63 ms including input delivery; our extra 80 ms grace
    /// was visible in every matched take. Menus and held cards still use
    /// the guards above; the top strip retains its own existing grace.
    static let columnLetGo: CFTimeInterval = 0
}

// MARK: - the top edge

/// Where the pointer stands against the window's top edge while the strip
/// is put away (⌘S with the tabs across the top, feedback #48), from the
/// window's top left: x in from its left edge, y down from its top, less
/// than 0 above it.
///
/// The left edge's rules, Dia's as measured there (EdgeReach), turned to
/// the top, but for two things. Above a window's top is the menu bar, where
/// a hand goes for a menu, so going out past the top is not reaching it:
/// only a rest on the very edge is. And the top is busier than the left
/// edge: edge to edge it is the page's own top, its header's links and
/// buttons a few points down, so the edge keeps quiet where the corner does
/// (bug #58), over what the page takes a click on and for a moment after a
/// press near the top. With the address bar or the bookmarks at the top,
/// the corner is theirs, Back and the first bookmarks, and brings nothing.
enum TopReach {
    /// On the very top edge, anywhere along it.
    static func at(_ point: CGPoint, width: CGFloat) -> Bool {
        point.x >= 0 && point.x <= width && point.y >= 0 && point.y <= Metrics.edgeWall
    }

    /// In the corner the lights live in, while nothing of Yab's own is
    /// there (`clear`).
    static func corner(_ point: CGPoint, clear: Bool) -> Bool {
        clear && point.x >= 0 && point.y >= 0
            && point.x <= Metrics.lightsCorner.width && point.y <= Metrics.lightsCorner.height
    }

    /// How long the pointer rests before the strip comes out: at the edge,
    /// or in the corner as long as at the left one. Nil
    /// where resting brings nothing, anywhere else, over what the page
    /// takes a click on, and for a moment after a press near the top.
    static func rest(edge: Bool, corner: Bool, hand: Bool, quiet: Bool) -> CFTimeInterval? {
        guard !hand, !quiet else { return nil }
        if edge { return edgeRest }
        if corner { return EdgeReach.cornerRest }
        return nil
    }

    /// The top strip keeps its existing rest while the column waits longer.
    static let edgeRest: CFTimeInterval = 0.15

    /// A press this near the top keeps the edge and the corner quiet for a
    /// moment (EdgeReach.pressQuiet): what comes up under the pointer is the
    /// page, and the next rest there is on it.
    static func near(_ point: CGPoint, width: CGFloat) -> Bool {
        point.x >= 0 && point.x <= width && point.y >= 0 && point.y <= Metrics.lightsCorner.height
    }

    /// The pointer keeps a strip brought out over the page: on it, a little
    /// under its foot or past the window's sides, or up above the window,
    /// on its way to the menu bar and back. What hangs from the strip, a
    /// menu, a folder's preview, a popover, keeps it too (Brim.stripHeld).
    static func keeps(_ point: CGPoint, width: CGFloat) -> Bool {
        point.x >= -foot && point.x <= width + foot && point.y <= Metrics.row + foot && point.y >= -above
    }

    /// How far past the strip's foot and the window's sides the pointer
    /// still counts as on it.
    static let foot: CGFloat = 12
    /// How far above the window it may go and keep the strip.
    static let above: CGFloat = 150
}

// MARK: - full screen

/// Full screen, the way Dia and Arc do it: no strip of lights and doors at
/// the top eating into the page. With the tabs down the left, the column
/// leaves the layout and the page has the whole screen; resting at its side
/// edge below macOS's menu bar slides the
/// column in over the page, and moving away from it lets it go again. With
/// the tabs across the top, the strip stays, and steps down out of the way of
/// the menu bar while it is down. The lights are macOS's own there, in the
/// title bar it brings down under the menu bar, not ours in the strip; with
/// the tabs down the left they stay ours, in the column's corner, docked or
/// out as a card, and the title bar stays put away.
@MainActor
final class Brim {
    private static var kept: [ObjectIdentifier: Brim] = [:]

    static func keep(_ window: NSWindow, for browser: Browser) {
        let key = ObjectIdentifier(window)
        if let existing = kept[key] {
            if existing.window === window { return }
            existing.drop()
            kept[key] = nil
        }
        kept[key] = Brim(window, browser: browser)
    }

    /// A closed secondary window drops its observers, subscriptions and timers.
    static func forget(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard let existing = kept[key], existing.window == nil || existing.window === window else { return }
        existing.drop()
        kept[key] = nil
    }

    /// A closed primary window stays kept for reopen, but stops its edge timer
    /// and mouse monitors while hidden.
    static func pause(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard let existing = kept[key], existing.window === window else { return }
        existing.paused = true
        existing.stopWatching()
    }

    /// The window is in macOS's move into full screen or out of it, from
    /// will to did. macOS draws that move from two pictures of the window,
    /// one before and one at the new size, and a page holds the second back
    /// until it has drawn itself at that size (WebKit's resize snapshot).
    /// The stage's own cover over a page made larger (StageView.cover) has
    /// to stay out of that picture: it stood over all but the page's old
    /// corner, so the whole move showed the page small in the top left of an
    /// empty screen, and went on showing it until the page had drawn again
    /// (register 1089).
    static func inFullScreenMove(_ window: NSWindow?) -> Bool {
        guard let window, let existing = kept[ObjectIdentifier(window)], existing.window === window else { return false }
        return existing.moving
    }

    private var moving = false {
        didSet {
            guard moving, !oldValue else { return }
            // A move that fails says so only to the window's delegate, with
            // no did: the flag goes on its own well after any move is over.
            fullScreenMoves += 1
            let move = fullScreenMoves
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                AppKitMainThread.sync {
                    if let self, self.fullScreenMoves == move { self.moving = false }
                }
            }
        }
    }
    private var fullScreenMoves = 0

    private weak var window: NSWindow?
    private weak var browser: Browser?
    private var ticking: Timer?
    private var letting: DispatchWorkItem?
    /// The pointer has been over the column since it came out. Until it has,
    /// the column stays out.
    private var visited = false
    private var dwell = EdgeReach.Dwell()
    /// A look when that rest is long enough, rather than at the next tick.
    private var restLook: DispatchWorkItem?
    /// The pointer went out past the window's left edge through it, and is
    /// still out there beside the window (EdgeReach.at).
    private var past = false
    /// Until when the lights' corner keeps quiet, after a press in it.
    private var cornerQuiet: CFTimeInterval = 0
    /// Presses in the window, heard while the pointer is watched.
    private var presses: Any?
    /// The pointer's moves, heard as they come, over the window and past it.
    private var moves: [Any] = []
    /// The same for the strip put away: when the pointer came to rest where
    /// resting brings it out, a look when that rest is long enough, the
    /// strip let go once the pointer has left it, and until when the top
    /// keeps quiet after a press near it (TopReach).
    private var stripResting: CFTimeInterval?
    private var stripLook: DispatchWorkItem?
    private var stripLetting: DispatchWorkItem?
    private var topQuiet: CFTimeInterval = 0
    /// A menu is open, any of the app's: a tab's in the strip among them.
    private var menuOpen = false
    /// When the pointer came into the seam above the page, and when it left
    /// the band with the lights (HeadBand).
    private var seamSince: CFTimeInterval?
    private var bandLeft: CFTimeInterval?
    /// How long the pointer rests in the seam before the band comes out: a
    /// hand on its way to the menu bar, or to a link at the top of the page,
    /// goes through it quicker than that.
    private static let seamRest: CFTimeInterval = 0.15
    /// How long the band waits once the pointer has left it.
    private static let bandGrace: CFTimeInterval = 0.35
    /// How far above the window the pointer may go and keep the band, on
    /// its way to the menu bar and back.
    private static let bandAbove: CGFloat = 150
    /// Where the pointer was at the last look, from the window's top left.
    private var lastPointer: CGPoint?
    private var keeping: Set<AnyCancellable> = []
    private var tokens: [NSObjectProtocol] = []
    private var paused = false
    /// Where the bench says the pointer is, in screen space, in place of
    /// the real one: a probe drives the edge without taking the Mac's
    /// pointer (Bench, "edge").
    static var benchPointer: NSPoint?
    /// Whether the page shows its pointing hand under the bench's pointer:
    /// the real cursor is wherever the Mac's pointer is.
    static var benchHand = false
    /// The window taken as the one in front, as a hand at its edge has it,
    /// on a Mac where something else keeps taking the focus from a probe.
    static var benchFront = false
    /// A menu taken as open, as a tab's is while it is up: the bench can't
    /// open a real one and go on asking while it tracks.
    static var benchMenu = false

    /// A press where the bench's pointer is, as a click there would be.
    static func benchPress(in window: NSWindow) {
        guard let pointer = benchPointer, let existing = kept[ObjectIdentifier(window)], existing.window === window else { return }
        existing.pressed(at: pointer)
    }

    /// A look at the bench's pointer now, as a move or a tick would take.
    static func benchLook(in window: NSWindow) {
        guard let existing = kept[ObjectIdentifier(window)], existing.window === window else { return }
        existing.moved()
    }

    private func drop() {
        stopWatching()
        keeping.removeAll()
        let center = NotificationCenter.default
        for token in tokens { center.removeObserver(token) }
        tokens = []
    }

    private init(_ window: NSWindow, browser: Browser) {
        self.window = window
        self.browser = browser
        let center = NotificationCenter.default
        // Outside full screen the pointer is only worth watching while the
        // column or the strip is put away, and there is a card to bring out.
        browser.prefs.changes(\.sideShut).combineLatest(browser.prefs.changes(\.sidebar), browser.prefs.changes(\.sideFlank), browser.prefs.changes(\.stripShut))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in AppKitMainThread.sync { self?.rewatch(); self?.light() } }
            .store(in: &keeping)
        // Menus are heard as they open and close, on the spot: while one is
        // open the main queue is the menu's.
        tokens = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] _ in
                AppKitMainThread.sync { self?.menuOpen = true }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { [weak self] _ in
                AppKitMainThread.sync { self?.menuOpen = false }
            },
            center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                AppKitMainThread.sync { self?.entering() }
            },
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                AppKitMainThread.sync { self?.settled() }
            },
            center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                AppKitMainThread.sync { self?.leaving() }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                AppKitMainThread.sync { self?.settled() }
            },
            // A primary window reopened after pause resumes watching if needed.
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                AppKitMainThread.sync {
                    self?.paused = false
                    self?.rewatch()
                }
            },
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] note in
                AppKitMainThread.sync {
                    guard let self, self.paused, let window = note.object as? NSWindow,
                          window.isVisible, window.occlusionState.contains(.visible) else { return }
                    self.paused = false
                    self.rewatch()
                }
            },
            // macOS gives the window its new size inside the move, where the
            // picture at that size is taken, and SwiftUI would lay the window
            // out at its next turn, after it: the page was given its size too
            // late to hold the picture back, and the move showed it at the old.
            // Laid out on the spot, the page has its size while macOS waits.
            // Posted synchronously, so `queue: nil`.
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: nil) { [weak self] note in
                AppKitMainThread.sync {
                    guard let self, self.moving, let window = note.object as? NSWindow else { return }
                    window.contentView?.layoutSubtreeIfNeeded()
                }
            },
        ]
        if window.styleMask.contains(.fullScreen) { entering(); settled() }
    }

    /// In and out of full screen the layout changes in one step, with no
    /// animation of its own. macOS is already animating the window from one
    /// size to the other; a spring on top of that moved the page's edge on
    /// every frame of it, and WebKit laid the page out again each time, the
    /// whole transition stuttered and froze.
    private func entering() {
        moving = true
        flip(to: true)
        light()
        watch()
    }

    private func leaving() {
        moving = true
        stopWatching()
        flip(to: false)
        light()
        rewatch()
    }

    /// Watching, or not, for the state the window is in now.
    private func rewatch() {
        guard let browser else { return }
        if paused || window?.isVisible == false {
            stopWatching()
            return
        }
        // The strip out over the page goes with the strip put away, whatever
        // else is watched: the tabs down the side for Mail, with the
        // column put away, left it out, and it came back over the page
        // with them, no pointer at the top.
        if !browser.stripAway, browser.stripPeek {
            stripLetting?.cancel()
            stripLetting = nil
            browser.quietly { browser.stripPeek = false }
        }
        if browser.fullScreen {
            watch()
            return
        }
        if browser.prefs.sidebar && (browser.prefs.sideShut || browser.prefs.sideFlank == .right) || browser.stripAway {
            watch()
        } else {
            stopWatching()
            if browser.headOut || browser.headShown { browser.moveHead(out: false) }
            if browser.sidePeek { browser.sidePeek = false }
        }
    }

    private func flip(to full: Bool) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            browser?.fullScreen = full
            browser?.sidePeek = false
            browser?.stripPeek = false
            browser?.menuDown = 0
            browser?.menuOut = false
        }
    }

    private func settled() {
        moving = false
        light()
    }

    /// Whose lights these are. In full screen with the tabs across the top
    /// macOS's, in the title bar it brings down; with the tabs down the left
    /// ours, in the column's corner as in a window, the column docked or out
    /// as a card, with that title bar put away. Out of full screen always ours.
    private func light() {
        guard let window, let browser else { return }
        // With the column on the right macOS's too: ours stand in the band
        // across a window's top (HeadBand), and full screen has none.
        let theirs = browser.fullScreen && (!browser.prefs.sidebar || browser.flank == .right)
        Lights.showTitleBar(!browser.fullScreen || theirs, of: window)
        Lights.showOwn(theirs, of: window)
        if browser.titleLights != theirs { browser.titleLights = theirs }
    }

    /// The pointer is looked at, not listened to: over the menu bar macOS
    /// has brought down, it sends the app nothing. Watching still lets a
    /// column already out stay there. Only in full screen, or while
    /// the column is put away.
    private func watch() {
        guard ticking == nil else { return }
        // Thirty a second: all it has to catch is the pointer reaching an
        // edge, and a thirtieth of a second is quicker than a hand gets there.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            AppKitMainThread.sync { self?.moved() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticking = timer
        // And every move is a look too, over the window and past its edge,
        // so the edge's rest starts, and the card's going, when the pointer
        // gets there, not up to a thirtieth of a second later. The ticks
        // stay for a pointer standing still, which sends nothing, and for
        // the menu bar, which sends the app nothing either.
        moves = [
            NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                AppKitMainThread.sync { self?.moved() }
                return event
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                AppKitMainThread.sync { self?.moved() }
            },
        ].compactMap { $0 }
        // Presses are listened to: a tap on a trackpad is over in less
        // than a look.
        presses = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            AppKitMainThread.sync {
                if let self, let window = self.window, event.window === window {
                    self.pressed(at: window.convertPoint(toScreen: event.locationInWindow))
                }
            }
            return event
        }
    }

    private func stopWatching() {
        ticking?.invalidate()
        ticking = nil
        letting?.cancel()
        letting = nil
        cancelRest()
        stripLetting?.cancel()
        stripLetting = nil
        stripLook?.cancel()
        stripLook = nil
        stripResting = nil
        if let presses { NSEvent.removeMonitor(presses) }
        presses = nil
        moves.forEach(NSEvent.removeMonitor)
        moves = []
    }

    private func cancelRest() {
        dwell = EdgeReach.Dwell()
        restLook?.cancel()
        restLook = nil
    }

    /// The number of the topmost window under a point on the screen, any
    /// app's.
    private static func top(under pointer: NSPoint) -> Int {
        NSWindow.windowNumber(at: pointer, belowWindowWithWindowNumber: 0)
    }

    /// The window's number and its child windows', as the window server
    /// numbers them.
    private static func own(_ window: NSWindow) -> Set<Int> {
        Set(([window] + (window.childWindows ?? [])).map(\.windowNumber))
    }

    /// Whether a window is an app's ordinary one, at the level documents
    /// and browsers are, and not the desktop's or one floating above.
    private static func ordinary(_ number: Int) -> Bool {
        guard number > 0,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]])?.first,
              let layer = info[kCGWindowLayer as String] as? Int else { return false }
        return layer == Int(CGWindowLevelForKey(.normalWindow))
    }

    /// The pointer is on another window and this one is not in front: the
    /// column and the strip it had out over the page go back, unless
    /// something hangs from them or a button is held, a drag on its way
    /// out. In full screen the strip's reveal is AppKit's, left to it.
    private func letGo(behind browser: Browser) {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        if browser.sidePeek, !columnHeld(browser) { Self.bring(browser, out: false) }
        if !browser.fullScreen, browser.stripPeek, !stripHeld(browser) { Self.bringStrip(browser, out: false) }
        if browser.headOut { browser.moveHead(out: false) }
    }

    /// A press in the lights' corner keeps it quiet for a moment: the button
    /// there was clicked, and what comes up under the pointer is the page.
    /// With the strip put away, a press anywhere near the top does the same
    /// for the top (TopReach.near).
    private func pressed(at pointer: NSPoint) {
        guard let window, let browser else { return }
        let frame = window.frame
        let fromLeft = pointer.x - frame.minX, fromTop = frame.maxY - pointer.y
        let now = CACurrentMediaTime()
        if browser.stripAway, TopReach.near(CGPoint(x: fromLeft, y: fromTop), width: frame.width) {
            topQuiet = now + EdgeReach.pressQuiet
        }
        guard browser.flank != .right, fromLeft >= 0, fromTop >= 0, fromLeft <= Metrics.lightsCorner.width,
              fromTop <= Metrics.lightsCorner.height else { return }
        cornerQuiet = now + EdgeReach.pressQuiet
    }

    /// How far the menu bar and the title bar under it reach into the
    /// window when they come down. Only the title bar on a screen with a
    /// notch, where full screen stops below the menu bar, or with the menu
    /// bar set to stay; no title bar when it is put away for the column's lights.
    /// The menu bar's own height is taken as the tallest of what AppKit
    /// says about it: the main menu's word for it, the status bar's, and
    /// how far the screen's usable area stops under its top. On a screen
    /// without a notch the menu bar comes down over the window, and the
    /// main menu's word alone can be short of the bar macOS draws there.
    private var menuReach: CGFloat {
        guard let window, let screen = window.screen else { return 0 }
        let bar = browser?.titleLights == true ? Lights.titleBarHeight(of: window) : 0
        guard window.frame.maxY >= screen.frame.maxY - 1 else { return bar }
        let inset = screen.frame.maxY - screen.visibleFrame.maxY
        let said = max(NSApp.mainMenu?.menuBarHeight ?? 0, NSStatusBar.system.thickness, inset <= 60 ? inset : 0)
        return (said > 0 ? said : 24) + bar
    }

    private func moved() {
        // Where the pointer was at the last look, for a move that went out
        // past the edge between two looks. Forgotten whenever there was no
        // look, so a pointer from before the window was in front counts for
        // nothing.
        let last = lastPointer
        lastPointer = nil
        guard let window, let browser, browser.active?.immersed != true else { cancelRest(); return }
        let pointer = Brim.benchPointer ?? NSEvent.mouseLocation
        // A window behind another app's has the pointer too while the
        // pointer is over it: its column comes out at its edge with no
        // click to bring the window forward first (#786). With the pointer
        // on some other window nothing here is looked at, so what this
        // window had out goes: nothing else would put it away again.
        let front = window.isKeyWindow || window.isMainWindow || Brim.benchFront
        guard EdgeReach.watches(front: front, onScreen: window.isVisible && window.occlusionState.contains(.visible),
                                frame: window.frame, pointer: pointer, top: Brim.top(under: pointer),
                                own: Brim.own(window)) else {
            cancelRest()
            // A rest at the top edge from before counts for nothing when
            // the pointer comes back to it: the strip waits a whole rest.
            stripResting = nil
            stripLook?.cancel()
            stripLook = nil
            letGo(behind: browser)
            return
        }
        let full = browser.fullScreen
        guard full || (browser.prefs.sidebar && browser.prefs.sideShut) || browser.headBand || browser.stripAway else { cancelRest(); return }
        let frame = window.frame
        let fromTop = frame.maxY - pointer.y
        // From the edge the column comes out of.
        let right = browser.flank == .right
        let fromLeft = right ? frame.maxX - pointer.x : pointer.x - frame.minX
        let here = CGPoint(x: fromLeft, y: fromTop)
        lastPointer = here
        let held = NSEvent.pressedMouseButtons != 0

        // The band with the lights above the page, beside a column on the
        // right (HeadBand): out once the pointer has rested in the seam
        // above the page, in a little after it has left the
        // band, or the window's top on the way to the menu bar. Held, it
        // stays as it is: that is the window being dragged by it.
        if browser.headBand {
            let now = CACurrentMediaTime()
            let overPage = fromLeft > browser.sideShown && fromLeft <= frame.width
            if !browser.headOut {
                bandLeft = nil
                if !held, overPage, fromTop >= 0, fromTop <= Backdrop.inset + 1 {
                    let since = seamSince ?? now
                    seamSince = since
                    if now - since >= Self.seamRest {
                        seamSince = nil
                        browser.moveHead(out: true)
                    }
                } else {
                    seamSince = nil
                }
            } else {
                seamSince = nil
                let inBand = overPage && fromTop >= 0 && fromTop <= Metrics.row + 2
                let above = fromTop < 0 && fromTop > -Self.bandAbove
                    && fromLeft > browser.sideShown - 20 && fromLeft <= frame.width + 20
                if held || inBand || above {
                    bandLeft = nil
                } else {
                    let since = bandLeft ?? now
                    bandLeft = since
                    if now - since >= Self.bandGrace {
                        bandLeft = nil
                        browser.moveHead(out: false)
                    }
                }
            }
        } else if browser.headOut || browser.headShown {
            seamSince = nil
            bandLeft = nil
            browser.moveHead(out: false)
        }

        // The vertical card clears the system menu. Horizontal tabs live
        // in that menu's native title-bar accessory instead; their state
        // is observed here only for controls anchored to the strip.
        let menu = full ? menuReach : 0
        if full, browser.stripAway {
            // Downloads and background-tab notices need to know whether
            // their anchor is visible. Mirror AppKit; do not animate it.
            let shown = FullscreenToolbarView.isRevealed(browser)
            if browser.stripPeek != shown { browser.quietly { browser.stripPeek = shown } }
        }
        // Horizontal tabs are an AppKit title-bar accessory. AppKit owns
        // their reveal and hysteresis; this pointer state is only for the
        // vertical column's clearance under the system menu.
        if full, browser.prefs.sidebar, !held {
            if fromTop <= 2, !browser.menuOut {
                withAnimation(Motion.arrive) {
                    browser.menuOut = true
                    browser.menuDown = menu
                }
            } else if fromTop > menu + (browser.prefs.sidebar ? Metrics.strip : Metrics.row), browser.menuOut,
                      !(browser.stripPeek && stripHeld(browser)) {
                withAnimation(Motion.depart) {
                    browser.menuOut = false
                    browser.menuDown = 0
                }
            }
        }

        // With the tabs across the top, the strip put away (⌘S) comes out
        // over the page from the window's top edge, as the column does from
        // the left one, on its own rests (TopReach), and goes back up as
        // the column goes, a moment after the pointer has left it, unless
        // something hanging from it is up. Its lights come with it, as the
        // column's do: the corner they live in is one of the places that
        // brings it. Nothing while a button is held, a selection or a drag,
        // out of the strip too; nothing while ⌘S moves it. Measured from
        // the left whichever side the column would hang on.
        if browser.stripAway, !full, !browser.stripMoving {
            let top = CGPoint(x: pointer.x - frame.minX, y: fromTop)
            if !browser.stripPeek {
                stripLetting?.cancel()
                stripLetting = nil
                let edge = TopReach.at(top, width: frame.width)
                let corner = TopReach.corner(top, clear: !browser.barShown && !browser.shelfShown)
                let now = CACurrentMediaTime()
                // WebKit sets the pointing hand over a link or a button.
                let hand = (edge || corner)
                    && (Brim.benchPointer == nil ? NSCursor.current == NSCursor.pointingHand : Brim.benchHand)
                let rest = TopReach.rest(edge: edge, corner: corner, hand: hand, quiet: now < topQuiet || corner && now < cornerQuiet)
                if held || rest == nil {
                    stripResting = nil
                    stripLook?.cancel()
                    stripLook = nil
                } else if stripResting == nil, let rest {
                    stripResting = now
                    // Looked at again the moment the rest is long enough.
                    let look = DispatchWorkItem { [weak self] in AppKitMainThread.sync { self?.moved() } }
                    stripLook?.cancel()
                    stripLook = look
                    DispatchQueue.main.asyncAfter(deadline: .now() + rest, execute: look)
                }
                if !held, let rest, let since = stripResting, now - since >= rest - 0.002 {
                    stripResting = nil
                    stripLook?.cancel()
                    stripLook = nil
                    Self.bringStrip(browser, out: true)
                }
            } else if held || TopReach.keeps(top, width: frame.width) || stripHeld(browser) {
                stripLetting?.cancel()
                stripLetting = nil
            } else if stripLetting == nil {
                // A moment's grace, as long as Dia's, then away (EdgeReach.letGo).
                let work = DispatchWorkItem { [weak self] in
                    AppKitMainThread.sync {
                        guard let self, let browser = self.browser else { return }
                        self.stripLetting = nil
                        guard !self.stripHeld(browser) else { return }
                        Self.bringStrip(browser, out: false)
                    }
                }
                stripLetting = work
                DispatchQueue.main.asyncAfter(deadline: .now() + EdgeReach.letGo, execute: work)
            }
        } else {
            stripResting = nil
        }

        // Full screen or not, only a column put away comes out as a card.
        if browser.prefs.sidebar, browser.prefs.sideShut {
            let reach = browser.prefs.sideWidth + Metrics.floatInset + Metrics.floatSafe
            // In a window only the left edge brings the column out; its top
            // edge is the window's own, to resize it by.
            let over = EdgeReach.inside(here, height: frame.height)
            // Gone over to another display, beside the window's edge: not
            // the edge, and not the card's either.
            let away = EdgeReach.away(pointer, window: frame, screen: window.screen?.frame)
            if browser.sidePeek { cancelRest() }
            if !browser.sidePeek {
                // A rest at the very edge brings it out, or out past it
                // beside the window, gone there through the edge (EdgeReach),
                // for a short moment, enough to tell a pointer that stopped
                // from one passing through. The full-screen menu bar brings no
                // column out, including where it meets the side edge (#223),
                // nor anything under it while it is down: on a screen
                // without a notch it comes down over the window, the title
                // bar AppKit brings under it too, and the lights' corner is
                // right below, where a hand going to the menu or coming back
                // from it rests (#265). Down until the pointer has left it
                // and the strip's height under it (menuOut above).
                // Nothing happens while a button is held: that is
                // a selection or a drag, headed elsewhere. On the right the
                // top is the menu bar's and macOS's lights', and the lights
                // are in sight in a window: only the edge.
                let belowMenu = !full || (!browser.menuOut && fromTop > menu)
                if over || away || here.y < 0 || here.y > frame.height {
                    past = false
                } else if EdgeReach.wall(here, last: last, height: frame.height) {
                    past = true
                }
                var edge = !away && EdgeReach.at(here, past: past, height: frame.height)
                // Out past the edge over a window beside this one: not the
                // edge (#1024). The window server is asked only then.
                if edge, !over, EdgeReach.covered(top: Brim.top(under: pointer), own: Brim.own(window), ordinary: Brim.ordinary) {
                    edge = false
                    past = false
                }
                let now = CACurrentMediaTime()
                let rest = belowMenu ? EdgeReach.rest(edge: edge) : nil
                let before = dwell.until
                let remaining = dwell.remaining(rest: held ? nil : rest, now: now)
                if dwell.until != before || remaining == nil {
                    restLook?.cancel()
                    restLook = nil
                }
                if let remaining, remaining > 0, restLook == nil {
                    // Prepare the card while it is still off screen, during
                    // the existing dwell. Its first visible frame should
                    // already have the floating look, without a second
                    // layout after the native host starts moving.
                    if !browser.sideCard {
                        browser.quietly { browser.sideCard = true }
                    }
                    // Looked at again the moment the rest is long enough.
                    let look = DispatchWorkItem { [weak self] in
                        AppKitMainThread.sync {
                            self?.restLook = nil
                            self?.moved()
                        }
                    }
                    restLook = look
                    // Preparation uses the dwell already in progress. A
                    // slow first card layout must not start another full
                    // dwell after the pointer has already waited for it.
                    let delay = max(0, remaining - (CACurrentMediaTime() - now))
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: look)
                }
                if remaining == 0 {
                    cancelRest()
                    past = false
                    letting?.cancel()
                    visited = true
                    bringOut()
                }
            } else if !away, EdgeReach.keeps(here, reach: reach, height: frame.height, full: full) || fromTop <= browser.menuDown {
                // Over the column, just past the window's edge beside it,
                // or up in the menu bar that came down with it.
                visited = true
                letting?.cancel()
                letting = nil
            } else if columnHeld(browser) {
                letting?.cancel()
                letting = nil
            } else if visited, !held, letting == nil {
                // Leave after the pointer has passed the card's safe area.
                let work = DispatchWorkItem { [weak self] in
                    AppKitMainThread.sync {
                        guard let self, let browser = self.browser else { return }
                        self.letting = nil
                        guard !self.columnHeld(browser) else { return }
                        Self.bring(browser, out: false)
                    }
                }
                letting = work
                DispatchQueue.main.asyncAfter(deadline: .now() + EdgeReach.columnLetGo, execute: work)
            }
        } else {
            cancelRest()
        }
    }

    /// Something that hangs from the strip out over the page is up, below
    /// it, out of what keeps it: a menu, a tab's own among them; a folder's
    /// preview to search and pick from, or a tab's card; a tab's name, a
    /// pin's letter or a folder's name being written; or a window over this
    /// one, a popover such as Change Icon's, the spaces' tray, the
    /// downloads' stack. The strip going took them with it, or left them
    /// hanging from nothing: Rename Tab… picked from a tab's menu named a
    /// tab gone up past the edge.
    private func stripHeld(_ browser: Browser) -> Bool {
        stripHolder(browser) != nil
    }

    /// What holds the strip out, in a word, or nil. Only the windows that
    /// hang from it count: a window's full-screen title bar, or a screen
    /// share's ring and pill, are over this one for good.
    private func stripHolder(_ browser: Browser) -> String? {
        if menuOpen || Brim.benchMenu { return "menu" }
        if let window, ActionMenu.isOpen(in: window) { return "menu" }
        let glance = browser.glance
        if glance.shown != nil || glance.shownFolder != nil { return "card" }
        return hanging(browser)
    }

    /// The same for the column put away and out over the page: what hangs
    /// from it out past its reach, and the look card standing beside it.
    /// Its ••• menu is wider than the column, and a hand going along it,
    /// or picking Edit Look… there, or going to the card's swatches, or
    /// out to see the page the card colors, put the column away under the
    /// menu and the card, which then stood beside nothing. Folder previews
    /// and tab cards with buttons take the pointer too; passive tab cards
    /// still go with the pointer leaving their row.
    private func columnHeld(_ browser: Browser) -> Bool {
        columnHolder(browser) != nil
    }

    private func columnHolder(_ browser: Browser) -> String? {
        if menuOpen || Brim.benchMenu { return "menu" }
        if let window, ActionMenu.isOpen(in: window) { return "menu" }
        if LookCard.shared.open { return "look" }
        let glance = browser.glance
        if glance.taking, glance.shown != nil || glance.shownFolder != nil { return "card" }
        return hanging(browser)
    }

    /// A name being written, Change Icon's picker, or a window hanging
    /// from this one.
    private func hanging(_ browser: Browser) -> String? {
        if browser.editingTab != nil || browser.editingPin != nil || browser.folderBook.naming != nil { return "name" }
        if IconPicking.shared.isHolding { return "icon" }
        // An extension's popup, NordPass's vault: the pointer going out over
        // the page put the column away and the popup with it, though only a
        // click outside closes it.
        if #available(macOS 15.4, *), ExtensionPopup.shared.isShown { return "extension" }
        if ChromiumPopupHost.shared.isShown { return "extension" }
        let hanging = window?.childWindows?.first { child in
            child.isVisible && (child is Tray || child is HoardStack || String(describing: type(of: child)).contains("Popover"))
        }
        return hanging.map { String(describing: type(of: $0)) }
    }

    /// What holds the strip out, for the bench: "" for nothing.
    static func benchHeld(in window: NSWindow, _ browser: Browser) -> String {
        kept[ObjectIdentifier(window)]?.stripHolder(browser) ?? ""
    }

    /// And the column.
    static func benchColumnHeld(in window: NSWindow, _ browser: Browser) -> String {
        kept[ObjectIdentifier(window)]?.columnHolder(browser) ?? ""
    }

    /// The strip put away brought out over the page, or let go back up past
    /// the top edge, as the pointer does it; the bench does the same (`ui
    /// peekStrip`). Its look and its place change in one transaction, on
    /// the card's curves, Dia's (CardMotion), or with the menu bar in full
    /// screen on its beat: the look goes on with no animation of its own
    /// (ContentView.stripGround), and only the strip's own view is drawn
    /// again, not the window's (StripPeek). Under Reduce Motion it is there,
    /// and then it is not, as ⌘S puts it (Browser.stripPace).
    static func bringStrip(_ browser: Browser, out: Bool, motion: Animation? = nil) {
        guard browser.stripPeek != out, browser.stripAway || !out else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduce ? nil : motion ?? (out ? CardMotion.arrive : CardMotion.leave)) {
            if out { browser.stripCard = true }
            browser.stripPeek = out
        }
    }

    /// The column out over the page as a card: its look set while it is
    /// still out of sight, then brought in, whole.
    private func bringOut() {
        guard let browser else { return }
        Self.bring(browser, out: true)
    }

    /// The card brought out, or let go back past the edge, as the pointer
    /// does it; the bench times the same (`pace side-out`, `side-in`).
    ///
    /// Its look and its place change in one transaction, with no animation
    /// of SwiftUI's: the column's view slides it (ColumnView.peek), told
    /// to by `sliding`. Its look set in a transaction of its own first, as
    /// it was, made SwiftUI lay the window out twice in one turn, and the
    /// animation around the second drew it all again, before the card could
    /// set off.
    static func bring(_ browser: Browser, out: Bool) {
        guard browser.sidePeek != out else { return }
        browser.peek.sliding = true
        browser.quietly {
            if out, !browser.sideCard { browser.sideCard = true }
            browser.sidePeek = out
        }
    }
}
