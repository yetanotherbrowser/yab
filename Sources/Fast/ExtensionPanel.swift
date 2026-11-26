import AppKit
import SwiftUI

// Site Controls, in one popover: ⌘E, or the sliders at the end of the
// address (SiteControls.swift). The page's actions, the extensions as tiles,
// what this site was allowed, the connection.
//
// An extension's popup is not a second popover opening over this one. The
// popover stays and its body is replaced: the list goes, the popup's page
// comes, the popover takes the page's size, the same surface, a different
// step. ⌘E on the popup brings the list back into it the same way. Esc
// closes it, whichever it holds.
//
// Timings follow the frequent path: this is opened many times a day, so it
// grows from its button and nothing travels. Only pinning, which is rare,
// is allowed to move something across it (ExtensionMenu).

@available(macOS 15.4, *)
@MainActor
final class ExtensionPanel: NSObject, NSPopoverDelegate {
    static let shared = ExtensionPanel()

    private var popover: NSPopover?
    /// What the popover holds while it is the list.
    private weak var host: NSViewController?

    var isShown: Bool { popover?.isShown == true }
    /// The popover's own window, while it is shown (bench `film`).
    var windowNumber: Int? { isShown ? popover?.contentViewController?.view.window?.windowNumber : nil }

    /// The tab the panel is about, and the view it hangs from when a door
    /// opened it, not ⌘E.
    private weak var tab: Tab?
    /// The browser the tab belongs to, when it was named: a small window's.
    private weak var browser: Browser?
    /// The sign-in's extensions it lists: the window's (ExtensionSignIns).
    private var owner: Extensions = .shared
    private weak var from: NSView?
    private var spot: (rect: NSRect, view: NSView)?
    /// The actual door/spot used by present, retained across the handover
    /// into Customize Site so its close heads back to the same place.
    private(set) var sourceRect: CGRect?

    /// ⌘E and the sliders. `from`, the door pressed; `spot`, a place in a
    /// view to hang from, the band's lock.
    func toggle(tab: Tab? = nil, browser: Browser? = nil, page: SitePage = .main, from: NSView? = nil,
                spot: (rect: NSRect, view: NSView)? = nil) {
        let state = SiteControlsState.shared
        // ⌘E over a small window, or over its popover, is about its page.
        let link = tab == nil && browser == nil ? LinkWindow.inFront.flatMap { $0.tab.isBlank ? nil : $0 } : nil
        let browser = browser ?? link?.browser
        let tab = tab ?? link?.tab ?? (browser ?? BrowserWindows.shared.activeBrowser ?? Extensions.shared.browser)?.active
        if isShown {
            // The same door again: put away. Another tab's, or the other
            // page asked for: the panel turns to it where it is.
            let same = state.openFor == tab?.id && state.page == page
            close()
            if same { return }
        }
        self.tab = tab
        self.browser = browser
        self.from = from
        self.spot = spot
        state.page = page
        state.openFor = tab?.id
        if let taken = ExtensionPopup.shared.handOver() {
            show(in: taken)
        } else {
            show(in: nil)
        }
    }

    func close() {
        popover?.performClose(nil)
    }

    private func show(in taken: NSPopover?) {
        // One list out at a time: ⌘E puts the downloads' away, as pressing
        // the downloads button puts this one away.
        let window = browser ?? BrowserWindows.shared.activeBrowser ?? Extensions.shared.browser
        window?.hoard.openAt = nil
        owner.menuOpen = false
        owner = Extensions.of(window, page: tab)
        let root: AnyView
        if let browser = window, let tab = tab ?? browser.active {
            root = AnyView(SiteControlsView(browser: browser, tab: tab, prefs: browser.prefs,
                                            translation: browser.pageTranslation, extensions: owner))
        } else {
            root = AnyView(ExtensionMenu(extensions: owner))
        }
        let host = NSHostingController(rootView: root)
        // Measured before sizing is turned off: without it the controller
        // answers 0 × 0 and the popover falls back to its own 320 × 320,
        // wider than the list by a strip of its material on either side.
        let size = host.view.fittingSize
        // The list says its height itself (follow), rather than the popover
        // snapping to it while the list is still on its way there.
        host.sizingOptions = []
        self.host = host
        stopFollowing()
        filter = ""
        let extensions = owner
        if let taken {
            taken.appearance = NSApp.effectiveAppearance
            ExtensionPanel.replace(in: taken, with: host)
            taken.contentSize = size
            taken.delegate = self
            popover = taken
        } else {
            let popover = NSPopover()
            popover.appearance = NSApp.effectiveAppearance
            popover.contentViewController = host
            popover.contentSize = size
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
            self.popover = popover
            // With nothing installed the puzzle isn't in the row; opening
            // puts it there, and the list waits a moment for it to land.
            let waiting = extensions.anchors[Extensions.menuAnchor]?.view?.window == nil
            extensions.menuOpen = true
            if waiting {
                land(popover, tries: 12)
            } else {
                present(popover)
            }
            return
        }
        extensions.menuOpen = true
    }

    /// Waits a frame at a time, a few at most, for the puzzle to be in the
    /// window, then shows the list from it, or from the fallback, if it
    /// never comes (the sidebar put away).
    private func land(_ popover: NSPopover, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self, weak popover] in
            guard let self, let popover, popover === self.popover else { return }
            let landed = self.owner.anchors[Extensions.menuAnchor]?.view?.window != nil
            if landed || tries <= 0 { self.present(popover) } else { self.land(popover, tries: tries - 1) }
        }
    }

    /// From the puzzle; with no puzzle on screen, the sidebar put away,
    /// from the middle of the window's top edge, pointing down.
    private func present(_ popover: NSPopover) {
        let extensions = owner
        if let from, from.window != nil {
            sourceRect = from.window?.convertToScreen(from.convert(from.bounds, to: nil))
            popover.show(relativeTo: from.bounds, of: from, preferredEdge: (from as? AnchorView)?.edge ?? .maxY)
        } else if let spot, spot.view.window != nil {
            sourceRect = spot.view.window?.convertToScreen(spot.view.convert(spot.rect, to: nil))
            popover.show(relativeTo: spot.rect, of: spot.view, preferredEdge: spot.view.isFlipped ? .maxY : .minY)
        } else if let anchor = extensions.anchors[Extensions.menuAnchor]?.view, anchor.window != nil {
            sourceRect = anchor.window?.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: extensions.menuEdge)
        } else if let content = (NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.minX > -10_000 }))?.contentView {
            let top = content.isFlipped ? 44 : content.bounds.maxY - 44
            let spot = NSRect(x: content.bounds.midX, y: top, width: 1, height: 1)
            sourceRect = content.window?.convertToScreen(content.convert(spot, to: nil))
            popover.show(relativeTo: spot, of: content, preferredEdge: content.isFlipped ? .maxY : .minY)
        } else {
            extensions.menuOpen = false
            return
        }
        // Shown from a press in the browser window, the popover's window
        // isn't key, and SwiftUI hover only tracks in the key window: the
        // rows lit only after a first click inside. Key at once, with no
        // control taking focus, so no ring lands on the first tile.
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
            window.makeFirstResponder(nil)
        }
    }

    /// Gives the popover up to an extension's popup, which puts its page in
    /// the list's place. Nil when the list isn't up.
    func handOver() -> NSPopover? {
        guard let popover, popover.isShown else { return nil }
        stopFollowing()
        self.popover = nil
        owner.menuOpen = false
        SiteControlsState.shared.openFor = nil
        SiteControlsState.shared.hiddenOpen = false
        return popover
    }

    /// An extension pressed in the list. One with a popup gets this popover
    /// for it; anything else closes the list first.
    func press(_ id: String) {
        owner.press(id, from: handOver())
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        popover = nil
        owner.menuOpen = false
        SiteControlsState.shared.openFor = nil
        SiteControlsState.shared.page = .main
        // What was hidden here is listed again only when asked for.
        SiteControlsState.shared.hiddenOpen = false
    }

    // MARK: - the edge following the list

    /// How the list is about to move, when it is about to.
    enum Motion {
        case pinning, filtering

        /// How far along, 0 to 1, `time` seconds in, the list's own curve,
        /// and whether it is done.
        func progress(_ time: TimeInterval) -> (CGFloat, Bool) {
            switch self {
            case .pinning:
                let spring = Spring(duration: 0.34, bounce: 0)
                return (CGFloat(spring.value(target: 1.0, time: time)), time >= spring.settlingDuration)
            case .filtering:
                let t = min(time / 0.13, 1)
                return (CGFloat(UnitCurve.easeOut.value(at: t)), t >= 1)
            }
        }
    }

    private var expected: Motion?
    private var filter = ""
    private var following: (from: CGFloat, to: CGFloat, start: CFTimeInterval, motion: Motion)?
    private var link: CADisplayLink?

    /// The next change of height is the list moving this way.
    func expect(_ motion: Motion) {
        expected = motion
    }

    /// The list's height, from the list: the popover's edge goes there on
    /// the curve the list is moving on when it is pinning; after a filter,
    /// which changes the list at once, quickly, so it uncovers or covers
    /// the change rather than jumping to it; at once for anything else.
    ///
    /// The list says its height from a geometry action, which SwiftUI runs
    /// inside its host's layout. A content size set there resized the
    /// popover's window inside that layout pass, and with the popover
    /// animating, AppKit ran the resize's animation in a run loop of its
    /// own right there: each of its frames another constraints pass of the
    /// one window pass, until AppKit threw (crashes #214 to #218, 0.40.1,
    /// row 1389). The size is set just after the pass instead.
    func follow(_ height: CGFloat, filter: String) {
        let motion: Motion? = filter != self.filter ? .filtering : expected
        self.filter = filter
        expected = nil
        guard let popover, let host, popover.contentViewController === host else { return }
        Self.afterLayout { [weak self, weak popover] in
            guard let self, let popover, popover === self.popover else { return }
            self.resize(popover, to: height, motion: motion)
        }
    }

    /// Runs `work` once the layout pass under way is over: on the next turn
    /// of the main run loop, never inside the pass that asked for it.
    static func afterLayout(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    private func resize(_ popover: NSPopover, to height: CGFloat, motion: Motion?) {
        guard let host, popover.contentViewController === host else { return }
        let now = popover.contentSize
        guard abs(now.height - height) > 0.5 else { return }
        guard let motion, popover.isShown, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopFollowing()
            popover.contentSize = NSSize(width: now.width, height: height)
            return
        }
        following = (now.height, height, CACurrentMediaTime(), motion)
        // Left to itself the popover animates a new size on its own curve.
        popover.animates = false
        if link == nil {
            let link = host.view.displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let following, let popover, let host, popover.contentViewController === host else {
            stopFollowing()
            return
        }
        let (progress, done) = following.motion.progress(CACurrentMediaTime() - following.start)
        let height = done ? following.to : following.from + (following.to - following.from) * progress
        popover.contentSize = NSSize(width: popover.contentSize.width, height: height.rounded())
        if done { stopFollowing() }
    }

    private func stopFollowing() {
        link?.invalidate()
        link = nil
        following = nil
        popover?.animates = true
    }

    /// Puts `controller` in the popover in place of what it holds, the two
    /// overlapping for a moment rather than one after the other: the old
    /// body stays on top, pinned to the top left corner, and fades while the
    /// popover takes the new one's size. The new one is shown at once.
    static func replace(in popover: NSPopover, with controller: NSViewController, fade: TimeInterval = 0.13,
                        completion: (() -> Void)? = nil) {
        let old = popover.contentViewController?.view
        popover.contentViewController = controller
        guard let old else { completion?(); return }
        let parent = controller.view
        old.removeFromSuperview()
        old.autoresizingMask = parent.isFlipped ? [.maxYMargin, .maxXMargin] : [.minYMargin, .maxXMargin]
        old.setFrameOrigin(NSPoint(x: 0, y: parent.isFlipped ? 0 : parent.bounds.height - old.frame.height))
        parent.addSubview(old)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fade
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            old.animator().alphaValue = 0
        }, completionHandler: {
            old.removeFromSuperview()
            completion?()
        })
    }
}

extension Browser {
    /// ⌘E: the extensions, the pinned first. macOS gives ⌘E to "use the
    /// selection for Find"; here Find takes what is selected by itself.
    func toggleExtensions() {
        if #available(macOS 15.4, *) { ExtensionPanel.shared.toggle() }
    }
}
