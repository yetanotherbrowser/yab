import AppKit
import SwiftUI
import WebKit

/// One carrier for the entire card. Its logical size never changes when
/// Peek opens: only Core Animation moves its existing composited surface.
struct PeekSurface<Content: View>: NSViewRepresentable {
    let browser: Browser
    let front: Bool
    let corner: CGFloat
    let padding: EdgeInsets
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> PeekSurfaceView {
        PeekSurfaceView()
    }

    func updateNSView(_ view: PeekSurfaceView, context: Context) {
        // A separate native host must retain the surrounding card's full
        // environment (tone, typography, accessibility and color scheme).
        view.host.rootView = AnyView(content.hosted(in: context.environment).ignoresSafeArea())
        view.configure(browser: browser, front: front, corner: corner, padding: padding)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PeekSurfaceView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleNSView(_ view: PeekSurfaceView, coordinator: ()) {
        view.detach()
    }
}

final class PeekSurfaceView: NSView {
    let card = PeekCardView(frame: .zero)
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    let shade = PeekShadeView(frame: .zero)
    let peek = PeekView()
    private weak var browser: Browser?
    private var front = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        card.wantsLayer = true
        card.layer?.masksToBounds = false
        card.layer?.cornerCurve = .continuous
        card.autoresizingMask = [.width, .height]
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        host.autoresizingMask = [.width, .height]
        shade.wantsLayer = true
        shade.autoresizingMask = [.width, .height]
        peek.autoresizingMask = [.width, .height]
        card.addSubview(host)
        card.addSubview(shade)
        addSubview(card)
        addSubview(peek)
        peek.bindSurface(card, shade: shade)
    }

    required init?(coder: NSCoder) { nil }

    func configure(browser: Browser, front: Bool, corner: CGFloat, padding: EdgeInsets) {
        self.browser = browser
        self.front = front
        let margins = [padding.leading, padding.top, padding.trailing, padding.bottom]
        if peek.depth.padding != margins {
            peek.depth.padding = margins
            // The panel's top room follows the card's margin above it.
            peek.needsLayout = true
        }
        peek.browser = browser
        peek.shape(corner: corner, flatTop: false)
        if front { attach() }
        else if browser.peekView === peek {
            peek.drop()
            browser.peekView = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, front { attach() }
        // Slid whole, band, page and paper, under the band with the
        // lights (Reshape.slide).
        if window != nil { Reshape.carriers.add(self) }
    }

    private func attach() {
        guard window != nil, let browser, browser.peekView !== peek else { return }
        browser.peekView?.drop()
        browser.peekView = peek
        // activeID changes before SwiftUI attaches the new half. Replay
        // the stored Peek into this carrier without depending on WebKit's
        // old/new StageView attachment order.
        if let page = browser.peeking, browser.peekFrom == browser.activeID {
            peek.present(page, shy: browser.privateBrowsing, instant: true, live: browser.isLive(page))
        } else {
            browser.followPeek()
        }
    }

    func detach() {
        peek.drop()
        if browser?.peekView === peek { browser?.peekView = nil }
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        host.frame = card.bounds
        shade.frame = card.bounds
        peek.frame = bounds
        peek.depth.refresh()
    }
}

/// Owns only the depth transform; SwiftUI and StageView manage their
/// layout and animations beneath this layer without replacing it.
///
/// It never clips: the card's edge has one owner, the page's stage
/// (docs/page-corners.md), and a clip here on the same outline was a second
/// cut there. What would show past the edge while the card is scaled, the
/// paper's hairline and shadow, fades out instead (PaperView.recede).
final class PeekCardView: NSView {
    func recede(_ on: Bool, animated: Bool) {
        for paper in papers { paper.recede(on, animated: animated) }
    }

    /// The papers in the card: the page's, under its band. Found when Peek
    /// comes or goes, never on a frame; nothing in a web view is looked at.
    var papers: [PaperView] {
        var found: [PaperView] = []
        var queue: [NSView] = subviews
        while let view = queue.popLast() {
            if let paper = view as? PaperView { found.append(paper); continue }
            if view is WKWebView || view is StageView { continue }
            queue.append(contentsOf: view.subviews)
        }
        return found
    }
}

/// AppKit keeps native child layers above a view's own sublayers. The
/// shade needs its own sibling after the host to stay above live WebKit.
final class PeekShadeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
