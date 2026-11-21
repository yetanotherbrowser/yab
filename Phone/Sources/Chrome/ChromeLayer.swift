import SwiftUI
import UIKit

/// Native ownership makes window gestures reject other mounted surfaces and
/// system dialogs even while their logical route is already closing.
struct ChromeLayer: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        ChromeHost(app: app).ignoresSafeArea()
    }
}

private struct ChromeHost: UIViewControllerRepresentable {
    let app: AppModel

    private func contents(_ context: Context) -> AnyView {
        AnyView(ChromeLayerContent(sourceFolded: app.chrome.folded).environment(app)
            .environment(\.self, context.environment))
    }

    func makeUIViewController(context: Context) -> ChromeHostController {
        let controller = ChromeHostController(app: app, contents: contents(context))
        _ = controller.view
        return controller
    }

    func updateUIViewController(_ controller: ChromeHostController, context: Context) {
        MainStalls.count("chromeHost")
        UpdateLoops.count(.chromeHost) {
            var inputs = UpdateLoops.Fingerprint(fields: [
                "controller": Double(ObjectIdentifier(controller).hashValue),
                "chrome.folded": app.chrome.folded ? 1 : 0,
                "reduced": context.environment.accessibilityReduceMotion || FieldMotion.reduced ? 1 : 0,
                "dark": context.environment.colorScheme == .dark ? 1 : 0,
                "transaction.animated": context.transaction.animation == nil ? 0 : 1,
                "transaction.disablesAnimations": context.transaction.disablesAnimations ? 1 : 0,
            ])
            inputs.rect("container.bounds", controller.view.bounds)
            inputs.rect("host.bounds", controller.host.view.bounds)
            inputs.insets("container.safeArea", controller.view.safeAreaInsets)
            inputs.insets("window.safeArea", controller.view.window?.safeAreaInsets ?? .zero)
            return inputs
        }
        controller.update(contents: contents(context), folded: app.chrome.folded,
                          reduced: context.environment.accessibilityReduceMotion || FieldMotion.reduced, transaction: context.transaction)
    }

    static func dismantleUIViewController(_ controller: ChromeHostController, coordinator: ()) {
        controller.view.isUserInteractionEnabled = false
    }
}

/// Empty space in the transparent native host must still reach the real page.
/// Ownership is restricted to the drawn controls and their minimum targets.
private final class ChromeRootView: UIView {
    let app: AppModel
    init(app: AppModel) { self.app = app; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let surface = app.surfaces
        guard !app.privateContentBlocked, !surface.coversChrome, !surface.settings,
              !surface.join, surface.chat == nil else { return nil }
        // All Tabs owns the bar even while the page's chrome is fading out.
        guard TabStack.of(app).gallery == nil else { return nil }
        // The empty screen has All Tabs' bar (Tabs/EmptyHomeLayer).
        guard !app.emptyHomeBar else { return nil }
        if surface.menu == .plate { return super.hitTest(point, with: event) }
        guard surface.menu == nil else { return nil }
        guard surface.chromeOpacity > 0.5 else { return nil }
        let folded = app.chrome.folded
        let hasNow = app.nowItem != nil
        let geometry = BottomToolbarGeometry(size: bounds.size, folded: folded, hasNow: hasNow, words: app.plateWordsWidth, verticalControls: app.workspace.verticalControls, leadingRail: app.workspace.leadingRail)
        let plateHeight = max(Metrics.touch, geometry.plate.height)
        let plateTouch = CGRect(x: geometry.plate.minX, y: geometry.plate.midY - plateHeight / 2,
                                width: geometry.plate.width, height: plateHeight)
        let sideTouch = geometry.sideOpacity > 0.5 && (geometry.back.contains(point) || geometry.plus.contains(point))
        let unfolded = ChromeGeometry(size: bounds.size, folded: false, hasNow: hasNow)
        let asking = app.downloads.asking(isPrivate: app.pageIsPrivate) != nil && DownloadAskCard.frame(in: unfolded).contains(point)
        let now = app.nowItem != nil && ChromeGeometry(size: bounds.size, folded: folded, hasNow: hasNow,
                                                                                  chipWidth: app.nowItem?.chipWidth(screen: bounds.width), verticalControls: app.workspace.verticalControls, leadingRail: app.workspace.leadingRail).now.contains(point)
        guard plateTouch.contains(point) || sideTouch || now || asking else { return nil }
        // SwiftUI's folded glass paints 34 points and may clip its hosting
        // wrapper's hit region. Route only the padding of the existing native
        // 44-point button here, after the same current surface guards above.
        if folded, surface.menu == nil, plateTouch.contains(point),
           !geometry.plate.contains(point), !isHidden, alpha > 0.01 {
            let centers = retainedCenters(in: self)
            if centers.count == 1, let center = centers.first,
               center.window === window,
               center.isEnabled, center.isUserInteractionEnabled,
               center.bounds.height >= Metrics.touch {
                var ancestor: UIView? = center
                var visible = true
                while let current = ancestor {
                    if current.isHidden || current.alpha <= 0.01 { visible = false; break }
                    if current === self { break }
                    ancestor = current.superview
                }
                if visible, ancestor === self {
                    return center.hitTest(center.convert(point, from: self), with: event)
                }
            }
        }
        return super.hitTest(point, with: event)
    }

    private func retainedCenters(in view: UIView) -> [ToolbarPlateButton] {
        let own = (view as? ToolbarPlateButton).map { [$0] } ?? []
        return own + view.subviews.flatMap { retainedCenters(in: $0) }
    }
}

final class ChromeHostController: UIViewController {
    let app: AppModel
    let host: UIHostingController<AnyView>
    private var lastFolded: Bool
    /// The plate's swipes, followed on the window: across pages tabs, up
    /// lifts the spaces. Only touches inside this host are its.
    private lazy var plateGestures = PlateGestures(app: app)
    private lazy var bottomEdgeUnfold = BottomEdgeUnfold(app: app)
    init(app: AppModel, contents: AnyView) {
        self.app = app
        lastFolded = app.chrome.folded
        host = UIHostingController(rootView: contents)
        super.init(nibName: nil, bundle: nil)
        host.safeAreaRegions = []
        host.sizingOptions = []
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        plateGestures.owner = view
        bottomEdgeUnfold.owner = view
        if let window = view.window {
            plateGestures.install(on: window)
            bottomEdgeUnfold.install(on: window)
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        plateGestures.uninstall()
        bottomEdgeUnfold.uninstall()
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }
    /// How many times SwiftUI updated this host (tests: ChromeHostTests).
    private(set) var updates = 0
    /// Reduce Motion's fold, waiting for SwiftUI's update to end: the newest
    /// contents and their transaction, applied inside one cross-dissolve.
    private var pendingFade: (contents: AnyView, transaction: Transaction)?
    /// SwiftUI calls this from inside its own update of the outer host. The
    /// chrome's host only takes its new contents here and is laid out in this
    /// frame's commit like any view: laying it out on the spot ran the chrome's
    /// whole SwiftUI graph inside the outer one's update, each time anything
    /// the chrome takes from the outer host changed (crash #38, 0.0.14: the
    /// watchdog killed Yab on its way out with the main thread in there).
    func update(contents: AnyView, folded: Bool, reduced: Bool, transaction: Transaction) {
        updates += 1
        let crossFade = reduced && !Motion.disabled && lastFolded != folded
        lastFolded = folded
        if pendingFade != nil || crossFade {
            // UIKit's cross-dissolve captures the real old and new fixed poses,
            // so the new one is laid out inside its block, after this update.
            // Native controls remain mounted; there is no second toolbar.
            let waiting = pendingFade != nil
            pendingFade = (contents, transaction)
            if !waiting { DispatchQueue.main.async { [weak self] in self?.fade() } }
            return
        }
        withTransaction(transaction) { host.rootView = contents }
        host.view.setNeedsLayout()
    }

    private func fade() {
        guard let (contents, transaction) = pendingFade else { return }
        pendingFade = nil
        UIView.transition(with: host.view, duration: Motion.fadeDuration,
                          options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]) {
            withTransaction(transaction) { self.host.rootView = contents }
            self.host.view.setNeedsLayout()
            self.host.view.layoutIfNeeded()
        }
    }
    override func loadView() {
        let root = ChromeRootView(app: app)
        root.backgroundColor = .clear
        root.accessibilityIdentifier = "bottom.toolbar.owner"
        view = root
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.frame = root.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

/// The page's chrome, as the prototype draws it: the round back button on
/// the left, the plate with the site in the middle, New Tab on the right,
/// all 50 high, 12 from the screen's edges and 26 from its bottom; the Now
/// line 10 over them when there is something to say. Scrolling down folds it:
/// the buttons go, the plate shrinks into a capsule, the Now line into one
/// word beside it.
private struct ChromeLayerContent: View {
    let sourceFolded: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Namespace private var pageControls

    var body: some View {
        GeometryReader { geo in
            // The spaces give the plate and the Now line way by their own move (FieldModel.spacesVeil).
            let veil = app.field.spacesVeil
            let shade = 1 - (veil ?? 0)
            let hidden = (app.surfaces.coversChrome && veil == nil) || app.surfaces.settings || app.surfaces.join || app.surfaces.chat != nil
                || app.emptyHomeBar
            let accessible = !hidden && veil == nil && app.surfaces.chromeOpacity > 0.5
                && TabStack.of(app).gallery == nil
            let reduced = accessibilityReduceMotion || FieldMotion.reduced
            let menuOpen = app.surfaces.menu == .plate
            let layout = ChromeGeometry(size: geo.size, folded: sourceFolded, hasNow: app.nowItem != nil,
                                        chipWidth: app.nowItem?.chipWidth(screen: geo.size.width), verticalControls: app.workspace.verticalControls, leadingRail: app.workspace.leadingRail)
            // The iPad's toolbar layout asks from its downloads button (TabletDownloads).
            let question = app.workspace.tabletControls ? nil : app.downloads.asking(isPrivate: app.pageIsPrivate)
            ZStack(alignment: .topLeading) {
                if let question {
                    let card = DownloadAskCard.frame(in: ChromeGeometry(size: geo.size, folded: false, hasNow: true))
                    DownloadAskCard(ask: question)
                        .id(question.id)
                        .frame(width: card.width, height: card.height, alignment: .bottom)
                        .position(x: card.midX, y: card.midY)
                        .transition(.downloadAsk)
                        .opacity(hidden ? 0 : app.surfaces.chromeOpacity * shade)
                } else if let item = app.nowItem {
                    NowLineView(item: item, folded: sourceFolded, isAccessible: accessible && !lent(item),
                                dismiss: app.nowDismissal(for: item)) { action in
                        app.tapNow(action: action, from: layout.now)
                    }
                    .id(item.id)
                    .frame(width: layout.now.width, height: layout.now.height)
                    .position(x: layout.now.midX, y: layout.now.midY)
                    .transition(.nowLine)
                    .animation(reduced ? nil : Motion.chromeFold.current, value: sourceFolded)
                    .opacity(hidden || lent(item) ? 0 : app.surfaces.chromeOpacity * shade)
                    .offset(y: 10 * (veil ?? 0))
                    .allowsHitTesting(!lent(item) && veil == nil)
                    .accessibilityHidden(lent(item))
                }
                GlassEffectContainer(spacing: Metrics.PageControls.morphSpacing) {
                    ZStack(alignment: .topLeading) {
                        SharedBottomToolbar(size: geo.size, sourceFolded: sourceFolded, reduced: reduced, isAccessible: accessible,
                                            glassNamespace: reduced ? nil : pageControls)
                    }
                }
                // A sheet over the page fades its body, never a second set of controls.
                .opacity(hidden ? 0 : app.surfaces.chromeOpacity * shade)
                // A swipe's pills, outside the container so they can fade.
                BottomPagingPills(size: geo.size, folded: sourceFolded)
                    .opacity(hidden ? 0 : app.surfaces.chromeOpacity)
                // Opaque, out of the plate itself (Chrome/PageMenu). Not under
                // the chrome's fade: it stays while it turns into the field.
                if menuOpen {
                    // The field covering the chrome is the menu's own morph's
                    // end, so only the other surfaces hide it.
                    let covered = app.surfaces.settings || app.surfaces.join || app.surfaces.chat != nil
                    PageMenuLayer(size: geo.size).opacity(covered ? 0 : 1)
                }
            }
            .allowsHitTesting(accessible)
            .accessibilityHidden(!accessible)
            .onChange(of: app.surfaces.menu) { old, new in
                if new == .plate {
                    FieldMotion.note(reduced ? Motion.crossFade : Motion.pageMenuOpen,
                                     instead: reduced ? Motion.pageMenuOpen : nil)
                }
                if old == .plate, new != .plate {
                    FieldMotion.note(reduced ? Motion.crossFade : Motion.pageMenuClose,
                                     instead: reduced ? Motion.pageMenuClose : nil)
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: app.browser.tab?.id) {
            app.chrome.unfold()
            if app.surfaces.menu == .plate { app.surfaces.closeMenu(); app.pageMenu.reset() }
        }
    }

    private func lent(_ item: NowItem) -> Bool { item.kind == .parked && app.surfaces.parkedLineLent }
}

/// Where each piece of the chrome is, in screen points, folded or not: the
/// prototype's numbers (Metrics.Chrome, Metrics.Now) on a screen of any size.
struct ChromeGeometry {
    let size: CGSize
    let folded: Bool
    let hasNow: Bool
    /// The Mac hint's chip hugs its words; any other line is the full width.
    var chipWidth: CGFloat? = nil
    /// The plate's words, measured at the folded size (wordsWidth): folded
    /// alone, the capsule hugs them. nil, the widest capsule.
    var words: CGFloat? = nil
    var verticalControls: Bool? = nil
    var leadingRail = false
    /// What the system reserves at this surface's left and right edges (a
    /// status column, a cutout, rounded corners). Set from the window by
    /// BrowserWorkspaceView, so every geometry built anywhere agrees on it.
    var sides = ChromeGeometry.effectiveSides

    var reservations = ChromeGeometry.windowReservations

    struct Reservations: Equatable {
        var occlusions: [CGRect] = []
        var divisions: [CGRect] = []
        var statusBarHeight: CGFloat = 0
        static let empty = Reservations()
    }
    nonisolated(unsafe) static var windowReservations = Reservations.empty

    private typealias C = Metrics.Chrome
    private typealias N = Metrics.Now

    nonisolated(unsafe) static var windowSides = Sides.zero
    static var effectiveSides: Sides { sidesDisabled ? .zero : windowSides }
    /// Test states only: a reserved column added to the window's own insets.
    /// Test states only: the chrome as it was, ignoring the window's sides.
    nonisolated(unsafe) static var sidesDisabled = false
    nonisolated(unsafe) static var extraSides = Sides.zero
    struct Sides: Equatable {
        var left: CGFloat
        var right: CGFloat
        static let zero = Sides(left: 0, right: 0)
        /// Legacy gallery surfaces use the full foot below a status column.
        /// Page viewports and the browser's foot row retain both sides instead.
        var foot: Sides { left == 0 || right == 0 ? .zero : self }
        /// A pane takes the window's inset only on the edge it touches.
        static func of(pane: CGRect, window size: CGSize, insets: UIEdgeInsets) -> Sides {
            Sides(left: pane.minX <= 0.5 ? insets.left : 0,
                  right: pane.maxX >= size.width - 0.5 ? insets.right : 0)
        }
    }

    /// The buttons' and the plate's middle line, unfolded.
    private var rowMid: CGFloat { size.height - C.bottom - C.height / 2 }
    var usesRail: Bool { verticalControls ?? (size.width >= 568 && size.width > size.height) }
    /// The plate belongs to the safe area even when the rail shares a column.
    private var rowSides: Sides {
        let start = min(max(0, sides.left), max(0, size.width))
        var intervals = [start...max(start, size.width - max(0, sides.right))]
        let band = CGRect(x: 0, y: min(rowMid - C.height / 2, foldedMid - C.minHeight / 2),
                          width: size.width, height: C.height + C.bottom)
        for region in reservations.divisions where region.intersects(band) {
            intervals = intervals.flatMap { span -> [ClosedRange<CGFloat>] in
                guard region.maxX > span.lowerBound && region.minX < span.upperBound else { return [span] }
                var result: [ClosedRange<CGFloat>] = []
                if region.minX > span.lowerBound { result.append(span.lowerBound...min(span.upperBound, region.minX)) }
                if region.maxX < span.upperBound { result.append(max(span.lowerBound, region.maxX)...span.upperBound) }
                return result
            }
        }
        guard let span = intervals.max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }) else { return sides }
        return Sides(left: span.lowerBound, right: size.width - span.upperBound)
    }
    private var columnLeft: Bool { sides.left > 0 && sides.right == 0 }
    private var columnRight: Bool { sides.right > 0 && sides.left == 0 }
    private var underColumn: Bool { usesRail && (columnLeft || columnRight) }
    private var railX: CGFloat {
        if underColumn {
            return columnLeft ? (sides.left - C.round) / 2 : size.width - (sides.right + C.round) / 2
        }
        return leadingRail ? rowSides.left + Metrics.Edge.bar : size.width - rowSides.right - Metrics.Edge.bar - C.round
    }
    private var railColumn: CGRect {
        CGRect(x: columnLeft ? 0 : size.width - sides.right, y: 0,
               width: columnLeft ? sides.left : sides.right, height: size.height)
    }

    private var railFoot: CGRect {
        var frame = CGRect(x: usesRail ? railX : size.width - rowSides.right - C.side - C.round,
                           y: rowMid - C.round / 2, width: C.round, height: C.round)
        if underColumn {
            // Work upward so overlapping reservations cannot put the foot back in a region.
            for region in reservations.occlusions.filter({ $0.intersects(railColumn) && $0.minY >= size.height / 2 }).sorted(by: { $0.minY > $1.minY }) {
                if frame.intersects(region) { frame.origin.y = region.minY - Metrics.Edge.bar - frame.height }
            }
        }
        return avoidingDivisions(frame)
    }

    private var railTop: CGFloat {
        guard underColumn else { return Metrics.statusBar }
        // Only the column's top half can push the top group down. The camera
        // can stand at the other end after rotation.
        let bottom = reservations.occlusions.filter {
            $0.intersects(railColumn) && $0.minY < size.height / 2
        }.map(\.maxY).max()
        let row = reservations.statusBarHeight > 0 && reservations.statusBarHeight < Metrics.statusBar ? reservations.statusBarHeight : Metrics.statusBar
        let top = max(Self.idleColumnBottom, (bottom ?? 0) + row)
        // Back and Sidebar stay above the space button at the foot, whatever the column grew to.
        return min(top, railFoot.minY - 2 * (C.round + Metrics.Edge.bar))
    }
    /// The cover's status column with nothing running (Duo simulator, 2026-10-30).
    static let idleColumnBottom: CGFloat = 172

    /// Move a control to the nearest safe piece beside an active fold. Frames
    /// already include the system's interactive margins, so add none here.
    private func avoidingDivisions(_ frame: CGRect) -> CGRect {
        let safe = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        var pieces = [safe]
        for region in reservations.divisions where region.intersects(safe) {
            pieces = pieces.flatMap { piece -> [CGRect] in
                guard piece.intersects(region) else { return [piece] }
                return [CGRect(x: piece.minX, y: piece.minY, width: max(0, region.minX - piece.minX), height: piece.height),
                        CGRect(x: max(piece.minX, region.maxX), y: piece.minY, width: max(0, piece.maxX - region.maxX), height: piece.height),
                        CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: max(0, region.minY - piece.minY)),
                        CGRect(x: piece.minX, y: max(piece.minY, region.maxY), width: piece.width, height: max(0, piece.maxY - region.maxY))]
            }
        }
        guard reservations.divisions.contains(where: { $0.intersects(frame) }) else { return frame }
        let candidates = pieces.filter { $0.width >= frame.width && $0.height >= frame.height }.map { piece in
            CGRect(x: min(max(frame.minX, piece.minX), piece.maxX - frame.width),
                   y: min(max(frame.minY, piece.minY), piece.maxY - frame.height), width: frame.width, height: frame.height)
        }
        return candidates.min { hypot($0.midX - frame.midX, $0.midY - frame.midY) < hypot($1.midX - frame.midX, $1.midY - frame.midY) } ?? frame
    }
    /// The capsule's middle line, folded.
    private var foldedMid: CGFloat { size.height - C.minBottom - C.minHeight / 2 }

    var back: CGRect {
        avoidingDivisions(CGRect(x: usesRail ? railX : rowSides.left + C.side, y: usesRail ? railTop : rowMid - C.round / 2, width: C.round, height: C.round))
    }

    var sidebar: CGRect {
        avoidingDivisions(CGRect(x: back.minX, y: back.maxY + Metrics.Edge.bar, width: C.round, height: C.round))
    }

    var space: CGRect {
        railFoot
    }

    var plate: CGRect { avoidingDivisions(rawPlate) }

    private var rawPlate: CGRect {
        guard folded else {
            // Centered between the system's columns, past the buttons at both ends.
            let span = size.width - rowSides.left - rowSides.right
            let width = min(span, max(Metrics.touch, min(C.plateWidth(screen: span), Metrics.Workspace.maximumPlate)))
            return CGRect(x: rowSides.left + (span - width) / 2, y: rowMid - C.height / 2, width: width, height: C.height)
        }
        if hasNow {
            return CGRect(x: pairLeft, y: foldedMid - C.minHeight / 2, width: C.minWidthBesideNow, height: C.minHeight)
        }
        let available = max(0, size.width - rowSides.left - rowSides.right)
        let width = min(available, words.map { min(C.minWidth, max(C.minHeight * 2, ceil($0) + C.minPadding * 2)) } ?? C.minWidth)
        return CGRect(x: rowSides.left + (size.width - rowSides.left - rowSides.right - width) / 2, y: foldedMid - C.minHeight / 2, width: width, height: C.minHeight)
    }

    /// The width of the folded plate's words, in the font its label draws them.
    @MainActor static func wordsWidth(_ words: String) -> CGFloat {
        let dynamicType = DynamicTypeSize(UITraitCollection.current.preferredContentSizeCategory) ?? .large
        let font = PlateWords.font(pointSize: C.minLabelFont, weight: C.labelWeight, dynamicType: dynamicType)
        return NSAttributedString(string: words, attributes: [.font: font, .kern: -0.02 * font.pointSize]).size().width
    }

    /// The small capsule keeps its drawn height while the address button
    /// gives the finger the same minimum target as every other control.
    var plateTouch: CGRect {
        let height = max(plate.height, Metrics.touch)
        return CGRect(x: plate.minX, y: plate.midY - height / 2, width: plate.width, height: height)
    }

    var now: CGRect { avoidingDivisions(rawNow) }

    private var rawNow: CGRect {
        guard folded else {
            let bottom = size.height - N.bottom
            if let chipWidth {
                return CGRect(x: rowSides.left + (size.width - rowSides.left - rowSides.right - chipWidth) / 2, y: bottom - N.chipHeight, width: chipWidth, height: N.chipHeight)
            }
            return CGRect(x: rowSides.left + Metrics.Edge.bar, y: bottom - N.height, width: N.width(screen: size.width - rowSides.left - rowSides.right), height: N.height)
        }
        return CGRect(x: pairLeft + C.minWidthBesideNow + C.minGap, y: foldedMid - N.minHeight / 2, width: N.minWidth, height: N.minHeight)
    }

    /// The folded capsule and the Now line's word, centered as one.
    private var pairLeft: CGFloat { rowSides.left + (size.width - rowSides.left - rowSides.right - (C.minWidthBesideNow + C.minGap + N.minWidth)) / 2 }

    var buttonOpacity: Double { folded && !usesRail ? 0 : 1 }
}

/// A round glass button of the chrome: 50 to see and to hit.
struct RoundChromeButton<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let id: String
    let label: String
    var tone: GlassTone = .light
    var isAccessible = true
    @ViewBuilder let content: Content
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content
                .frame(width: Metrics.Chrome.round, height: Metrics.Chrome.round)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect((tone.isDark ? tone.glass(for: .dark) : .regular).interactive(), in: Circle())
        .glassEffectTransition(.identity)
        .environment(\.colorScheme, tone.isDark ? .dark : colorScheme)
        .accessibilityIdentifier(isAccessible ? id : "")
        .accessibilityLabel(label)
        .accessibilityHidden(!isAccessible)
        .allowsHitTesting(isAccessible)
    }
}

extension AnyTransition {
    /// The Now line arriving from 8 below, transparent, and leaving the same way, quicker.
    static var nowLine: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: Metrics.Now.goneDrop)).animation(Motion.nowArrive.animation),
            removal: .opacity.combined(with: .offset(y: Metrics.Now.goneDrop)).animation(Motion.nowGone.animation)
        )
    }
}

extension AppModel {
    /// The plate's words measured folded: the capsule hugs them (ChromeGeometry.words).
    var plateWordsWidth: CGFloat { ChromeGeometry.wordsWidth(browser.tab.map(PlateLabel.address) ?? "New Tab") }
}
