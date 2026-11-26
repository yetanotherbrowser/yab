import AppKit
import SwiftUI

/// In full screen the strip belongs to AppKit's sliding title bar. A second
/// pointer-driven animation cannot stay in phase with the system menu bar.
/// Outside full screen the same host lives in the browser's overlay.
struct FullscreenToolbar<Content: View>: NSViewRepresentable {
    let fullScreen: Bool
    let pinned: Bool
    let enabled: Bool
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> FullscreenToolbarView { FullscreenToolbarView() }

    func updateNSView(_ view: FullscreenToolbarView, context: Context) {
        view.host.rootView = AnyView(content.hosted(in: context.environment))
        view.configure(fullScreen: fullScreen, pinned: pinned, enabled: enabled)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FullscreenToolbarView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: enabled ? Metrics.row : 0)
    }

    static func dismantleNSView(_ view: FullscreenToolbarView, coordinator: ()) { view.detach() }
}

@MainActor
final class FullscreenToolbarView: NSView {
    let host = WindowHosting.host(AnyView(EmptyView()))
    private let accessory = NSTitlebarAccessoryViewController()
    private let slot = NSView()
    private weak var owner: NSWindow?
    private var fullScreen = false
    private var enabled = true

    /// State for controls anchored to the strip, never an input to the
    /// accessory's placement. AppKit can put it in its own toolbar window.
    static func isRevealed(_ browser: Browser) -> Bool {
        guard let strip = StripView.of(browser), !strip.isHiddenOrHasHiddenAncestor,
              let window = strip.window, window.isVisible, let screen = window.screen else { return false }
        let shown = window.convertToScreen(strip.convert(strip.visibleRect, to: nil)).intersection(screen.frame)
        return !shown.isNull && shown.height > 1
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.safeAreaRegions = []
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        slot.frame = NSRect(x: 0, y: 0, width: 0, height: Metrics.row)
        accessory.view = slot
        accessory.layoutAttribute = .bottom
        accessory.isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func configure(fullScreen: Bool, pinned: Bool, enabled: Bool = true) {
        self.fullScreen = fullScreen
        self.enabled = enabled
        let height = pinned ? Metrics.row : 0
        if accessory.fullScreenMinHeight != height { accessory.fullScreenMinHeight = height }
        attach()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
    }

    private func attach() {
        guard let window else { detach(); return }
        if owner !== window {
            detach()
            // AppKit decides whether to configure automatic reveal during
            // fullscreen entry. Register before that transition, including
            // when vertical tabs currently make this accessory hidden.
            accessory.isHidden = true
            owner = window
            window.addTitlebarAccessoryViewController(accessory)
        }
        let native = fullScreen && enabled
        let parent = native ? slot : self
        if host.superview !== parent {
            host.removeFromSuperview()
            parent.addSubview(host)
        }
        host.frame = parent.bounds
        if accessory.isHidden == native { accessory.isHidden = !native }
    }

    func detach() {
        if let owner, let index = owner.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
            owner.removeTitlebarAccessoryViewController(at: index)
        }
        owner = nil
        if host.superview !== self {
            host.removeFromSuperview()
            addSubview(host)
        }
        host.frame = bounds
    }

    override func layout() {
        super.layout()
        if host.superview === self { host.frame = bounds }
    }
}
