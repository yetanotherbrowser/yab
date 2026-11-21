import SwiftUI
import UIKit
import WebKit

/// The page, the whole screen under the status bar and the chrome. It steps
/// back behind sheets (Surfaces.recede): a little smaller toward a point a
/// third down, its corners rounding, the screen's white around it (the
/// scrim darkens both).
struct PageLayer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let recede = app.surfaces.recede
        let space = app.browser.space
        let between = colorScheme == .dark && !space.isPrivate ? space.folderGround(dark: true) : space.tint
        let mayInteract: @MainActor (Tab.ID) -> Bool = { [weak app] id in
            guard let app else { return false }
            return app.browser.tab?.id == id && app.privateLock.isActive && !app.privateContentBlocked
                && !app.surfaces.coversChrome && app.surfaces.chat == nil
                && app.surfaces.menu == nil && !app.surfaces.settings && !app.surfaces.join
        }
        let interactive = app.browser.tab.map { mayInteract($0.id) } ?? false
        let state = app.browser.tab.flatMap { app.chrome.pageStates[$0.id] } ?? .idle
        let swiping = app.surfaces.pageSwipe != nil
        // Pulled from the left edge (Back/): the page follows the finger over
        // what BackRevealLayer shows under it.
        let back = app.backStack.swipe.flatMap { $0.tab == app.browser.tab?.id ? $0 : nil }
        let backPose = back.map { BackPose(swipe: $0, width: app.backStack.width) }
        PageHost(tab: app.browser.tab, pool: app.pages, storeRevision: app.websiteStoreRevision,
                 state: state, pane: app.workspace.paneFrame, interactionsEnabled: interactive, mayInteract: mayInteract,
                 chrome: PageViewport.Chrome(folded: app.chrome.folded, hasNow: app.nowItem != nil,
                                             visible: !app.workspace.tabletControls && !app.surfaces.coversChrome && app.surfaces.chromeOpacity > 0.5,
                                             verticalControls: app.workspace.verticalControls, leadingRail: app.workspace.leadingRail))
            .accessibilityIdentifier("page.host")
            // Paging through tabs: the page is a card with the screen's
            // corners and follows the finger, the space's color between (Paging/).
            .clipShape(RoundedRectangle(cornerRadius: swiping ? Metrics.Page.cardCorner : backPose?.pageRadius ?? 0,
                                        style: .continuous))
            .offset(x: (app.surfaces.pageSwipe?.offset ?? 0) + (back?.offset ?? 0))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.Column.pageRadius * recede, style: .continuous))
            .scaleEffect(1 - Metrics.Column.pageShrink * recede, anchor: Metrics.Page.recedeAnchor)
            .background(back != nil ? Color.clear : swiping ? Color(rgb: between) : Ink.ground)
            .ignoresSafeArea()
    }
}

/// The tab in front's web view, swapped in when the tab changes.
private struct PageHost: UIViewRepresentable {
    let tab: Tab?
    let pool: WebPool
    let storeRevision: Int
    let state: WebPool.PageState
    let pane: CGRect
    let interactionsEnabled: Bool
    let mayInteract: @MainActor (Tab.ID) -> Bool
    let chrome: PageViewport.Chrome

    func makeUIView(context: Context) -> PageContainer { PageContainer() }

    func updateUIView(_ container: PageContainer, context: Context) {
        MainStalls.count("pageHost")
        UpdateLoops.count(.pageHost) {
            var inputs = UpdateLoops.Fingerprint(fields: [
                "container": Double(ObjectIdentifier(container).hashValue),
                "pool": Double(ObjectIdentifier(pool).hashValue),
                "hasTab": tab == nil ? 0 : 1,
                "storeRevision": Double(storeRevision),
                "interactionsEnabled": interactionsEnabled ? 1 : 0,
                "fixturesEnabled": pool.fixturesEnabled ? 1 : 0,
                "state.isLoading": state.isLoading ? 1 : 0,
                "state.progress": state.progress,
                "state.canGoBack": state.canGoBack ? 1 : 0,
                "state.canGoForward": state.canGoForward ? 1 : 0,
                "state.readerAvailable": state.readerAvailable ? 1 : 0,
                "state.readerEnabled": state.readerEnabled ? 1 : 0,
                "state.hasFailure": state.failure == nil ? 0 : 1,
            ])
            inputs.chrome(chrome)
            for (source, count) in pool.scrollSources { inputs.fields["scroll." + source] = Double(count) }
            inputs.rect("container.bounds", container.bounds)
            inputs.rect("container.frame", container.frame)
            inputs.insets("container.safeArea", container.safeAreaInsets)
            inputs.insets("window.safeArea", container.window?.safeAreaInsets ?? .zero)
            return inputs
        }
        container.windowPane = pane
        container.accessibilityCovered = !interactionsEnabled
        container.pool = pool
        pool.bindPageInteractions(to: container, enabled: interactionsEnabled, visibility: mayInteract)
        container.chrome = chrome
        container.fixturesEnabled = pool.fixturesEnabled
        guard let tab else {
            container.show(nil)
            return
        }
        // Once per update, not once per input: an offset or scale SwiftUI put
        // on the page since moves its hardware edges without a layout pass.
        // Cache these edges before activation can make or restore a page.
        container.updateViewport()
        container.show(pool.activate(tab))
        container.showFailure(state.failure, tab: tab.id, isPrivate: tab.isPrivate)
    }

    static func dismantleUIView(_ container: PageContainer, coordinator: ()) {
        container.pool?.releasePageInteractions(from: container)
        container.showFailure(nil, tab: "")
        container.show(nil)
    }
}

/// Holds the one web view in front, edge to edge.
final class PageContainer: UIView {
    private weak var current: WKWebView?
    private var failureHost: UIHostingController<PageLoadFailureView>?
    private var failureShown = false
    private lazy var focusZoom = PageFocusZoom { [weak self] in
        self?.current?.superview === self ? self?.current : nil
    }
    var accessibilityCovered = false {
        didSet { updateAccessibility() }
    }
    // PageHost assigns these on every SwiftUI update; only a change reaches
    // the page (crash #105 was sampled in a re-apply of the same viewport).
    weak var pool: WebPool? {
        didSet { if pool !== oldValue { updateViewport() } }
    }
    var chrome = PageViewport.Chrome(folded: false, hasNow: false, visible: true) {
        didSet { if chrome != oldValue { updateViewport() } }
    }
    var fixturesEnabled = true {
        didSet { if fixturesEnabled != oldValue { updateViewport() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AppearanceColors.ui(0xFFFFFF, 0x121214)
        clipsToBounds = true
        _ = focusZoom
        // The page makes room under a keyboard its own field brought up.
        let center = NotificationCenter.default
        keyboardObservers = [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillChangeFrameNotification,
                             UIResponder.keyboardWillHideNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    PageKeyboard.note(note)
                    self?.updateViewport()
                }
            }
        }
    }

    private var keyboardObservers: [NSObjectProtocol] = []

    isolated deinit {
        for observer in keyboardObservers { NotificationCenter.default.removeObserver(observer) }
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func show(_ view: WKWebView?) {
        guard view !== current || view?.superview !== self else { return }
        if current?.superview === self {
            current?.accessibilityElementsHidden = false
            current?.accessibilityElements = nil
            current?.removeFromSuperview()
        }
        current = view
        guard let view else {
            showFailure(nil, tab: "")
            return
        }
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // A retained page may still have its neighbor or companion's insets.
        // Give it this host's viewport before attaching it to the window.
        updateViewport(for: view)
        addSubview(view)
        updateAccessibility()
        updateViewport()
        // A retiring SwiftUI host can update once after its replacement
        // attached this view. Reclaim it after that teardown, only while
        // this host is still on screen and still owns the same document.
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.window != nil, self.current === view else { return }
            self.show(view)
            self.updateViewport()
        }
    }

    func showFailure(_ failure: PageLoadFailure?, tab: Tab.ID, isPrivate: Bool = false) {
        failureShown = failure != nil
        updateAccessibility()
        guard let failure, let pool else {
            if let host = failureHost {
                host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
                failureHost = nil
            }
            return
        }
        let contents = PageLoadFailureView(failure: failure, isPrivate: isPrivate, retry: { [weak pool] in
            _ = pool?.retryFailure(tab, expected: failure.id)
        })
        if let host = failureHost { host.rootView = contents }
        else {
            let host = UIHostingController(rootView: contents)
            // The pane pads itself by the page viewport; the window's own safe
            // area would count the hardware edges twice.
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            failureHost = host
            addSubview(host.view)
        }
        updateAccessibility()
        updateViewport()
    }

    private func updateAccessibility() {
        accessibilityElementsHidden = accessibilityCovered
        // WebKit's remote document can outlive SwiftUI's hidden wrapper.
        accessibilityElements = accessibilityCovered ? [] : nil
        if current?.superview === self {
            current?.accessibilityElementsHidden = accessibilityCovered || failureShown
            current?.accessibilityElements = accessibilityCovered || failureShown ? [] : nil
        }
        failureHost?.view.accessibilityElementsHidden = accessibilityCovered
    }

    private func attachFailureHost() {
        guard let host = failureHost, host.parent == nil else { return }
        var responder: UIResponder? = self.next
        while let current = responder {
            if let parent = current as? UIViewController {
                parent.addChild(host); host.didMove(toParent: parent); return
            }
            responder = current.next
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        MainStalls.count("pageLayout")
        if current?.superview === self { current?.frame = bounds }
        updateViewport()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateViewport()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateViewport()
    }

    var windowPane = CGRect.zero

    func updateViewport(for incoming: WKWebView? = nil) {
        guard let window, !bounds.isEmpty else { return }
        let view = incoming ?? (current?.superview === self ? current : nil)
        // SwiftUI ignores safe areas to keep the page edge to edge. The
        // window still supplies the hardware edges, in our local coordinates.
        var windowInsets = window.safeAreaInsets
        windowInsets.left += ChromeGeometry.extraSides.left
        windowInsets.right += ChromeGeometry.extraSides.right
        let safe = convert(window.bounds.inset(by: windowInsets), from: window)
        let extent = convert(window.bounds, from: window)
        // A horizontal page swipe moves the whole viewport. Its translation
        // is not a hardware inset, even when the page crosses the window edge.
        let hardware = UIEdgeInsets(top: max(0, safe.minY - bounds.minY),
                                    left: windowPane.isEmpty || windowPane.minX <= 0.5 ? max(0, safe.minX - extent.minX) : 0,
                                    bottom: max(0, bounds.maxY - safe.maxY),
                                    right: windowPane.isEmpty || windowPane.maxX >= window.bounds.width - 0.5 ? max(0, extent.maxX - safe.maxX) : 0)
        let viewport = PageViewport(size: bounds.size, hardware: hardware, chrome: chrome)
        if !fixturesEnabled {
            if let pool { pool.setViewport(viewport, visible: view) }
            else if let view { viewport.apply(to: view) }
        } else if hardware.left > 0 || hardware.right > 0, let view {
            // Device captures must exercise the same side insets as live pages.
            // Portrait fixtures without a side column keep their atlas layout.
            viewport.apply(to: view)
        }
        if let host = failureHost {
            attachFailureHost()
            // WebKit's viewport already fits any transient smaller frame.
            let visible = fixturesEnabled ? viewport.current : (view?.scrollView.verticalScrollIndicatorInsets ?? viewport.current)
            // Cover the page edge to edge and inset only the words. A frame
            // inset by the bars left the page the failed navigation started
            // from showing under the toolbar and the status bar.
            host.view.frame = bounds
            let insets = EdgeInsets(top: visible.top, leading: visible.left,
                                    bottom: visible.bottom, trailing: visible.right)
            if host.rootView.insets != insets { host.rootView.insets = insets }
            bringSubviewToFront(host.view)
        }
    }
}
