import Foundation
import UIKit
import WebKit

extension StateCatalog {
    static let workspace: [NamedState] = [
        NamedState("workspace.stack", "Folded rail stack", "The outer stack remains usable while the address is folded.") { app in
            await StateCatalog.named("stack.1")?.apply(app)
            app.chrome.setFolded(true)
        },
        NamedState("workspace.form", "Two documents", "Independent drafts, scroll and history in the shared pool.") { app in
            let first = Tab(id: "workspace-primary", title: "First document", site: "First document", icon: "globe", page: "workspace")
            let second = Tab(id: "workspace-secondary", title: "Second document", site: "Second document", icon: "globe", page: "workspace")
            app.browser.open(first, deduplicate: false)
            app.workspace.openBeside(current: first.id, other: second.id)
            app.browser.open(second, deduplicate: false)
            // Fixture navigation needs the same page records as the address field.
            for tab in [first, second] {
                app.field.history.remember(tab, in: tab.id)
                var next = tab
                next.page = "workspace-next"
                next.title = "Next workspace document"
                app.field.history.remember(next, in: tab.id)
            }
            _ = app.pages.view(for: first)
            _ = app.pages.activate(second)
        },
        NamedState("workspace.single", "Full spread", "Opening a wide window does not create a second page.") { _ in },
        NamedState("tablet.strip", "iPad: tabs across the top", "Show Tabs in Sidebar off: the Mac's tab bar under the status bar, the address band on the page.") { app in
            app.workspace.preferences.tabsInSidebar = false
        },
        NamedState("tablet.band", "iPad: address bar on", "Show Address Bar on: the band over the page card holds Back, Forward and Reload; the sidebar's header only its door.") { app in
            app.workspace.preferences.addressBars = true
        },
        NamedState("tablet.hidden", "iPad: sidebar hidden", "The sidebar away: the band holds its door, the page's doors, + and All Tabs.") { app in
            app.workspace.preferences.sidebarShown = false
        },
        NamedState("tablet.empty", "iPad: empty space, sidebar hidden", "No tab in the space and the sidebar away: the page area's band keeps the sidebar's door and New Tab.") { app in
            app.browser.createSpace(name: "Empty", emoji: "🌱", look: SpaceLook(color: RGB(168, 195, 160)))
            app.workspace.preferences.sidebarShown = false
        },
        NamedState("tablet.site.desktop", "iPad: desktop site", "Site Controls: Desktop site On, as every site is on an iPad until it is asked for as a mobile one.") { app in
            openSiteControls(app)
        },
        NamedState("tablet.site.mobile", "iPad: mobile site", "Site Controls for a site asked for as a mobile one: Desktop site Off, the page in its phone layout.") { app in
            if let tab = app.browser.tab {
                app.siteSettings.setVersion(.mobile, for: app.siteHost(of: tab), isPrivate: false)
                // The page again, as the switch would: it is the phone layout, as it says.
                _ = app.pages.activate(tab)
                app.pages.reload(tab.id)
                await app.pages.waitUntilPainted(tab.id, timeout: .seconds(12))
            }
            openSiteControls(app)
        },
        NamedState("tablet.split.narrow", "iPad: narrow split pane", "Two pages, the sidebar away, the focused one at the 320-point minimum: its address keeps room, + holds the tab buttons.") { app in
            await StateCatalog.turn(.landscape)
            app.workspace.preferences.sidebarShown = false
            app.workspace.preferences.resizeSplit(to: 1, save: false)
            await StateCatalog.named("workspace.two")?.apply(app)
        },
        NamedState("workspace.two", "Two pages", "Two real pooled pages; the second one owns the controls.") { app in
            guard let current = app.browser.tab,
                  let other = app.browser.space.allTabs.first(where: { $0.id != current.id && !$0.isMail }) else { return }
            app.workspace.openBeside(current: current.id, other: other.id)
            app.browser.select(other.id)
            _ = app.pages.view(for: current)
            _ = app.pages.activate(other)
        },
        NamedState("workspace.sides", "Reserved right column", "80 points reserved at the right, as a foldable's status column: the page runs under it, controls and the scroll bar stay clear of it.") { app in
            ChromeGeometry.extraSides = .init(left: 0, right: 80)
            app.workspace.reservations.statusBarHeight = 22
        },
        NamedState("duo.column.right", "Right status column", "Synthetic 84-point column; the page runs under it, the foot inside the safe area.") { app in
            await StateCatalog.turn(.landscapeRight)
            StateCatalog.duoColumn(app, left: false)
        },
        NamedState("duo.column.left", "Left status column", "The same reserved column and rail on the left.") { app in
            await StateCatalog.turn(.landscapeRight)
            StateCatalog.duoColumn(app, left: true)
        },
        NamedState("duo.rotation.right", "Loaded page, right column", "A local viewport ruler before rotating and restoring chrome.") { app in
            await StateCatalog.duoRotation(app, left: false)
        },
        NamedState("duo.rotation.left", "Loaded page, left column", "The same viewport ruler with the opposite column.") { app in
            await StateCatalog.duoRotation(app, left: true)
        },
        NamedState("duo.activity", "Expanded Live Activity", "A taller synthetic occlusion moves Back and Sidebar down.") { app in
            BrowserWorkspace.regularForced = true
            await StateCatalog.turn(.landscapeRight)
            StateCatalog.duoColumn(app, left: false, activity: true)
        },
        NamedState("duo.division", "Active fold", "The foot controls avoid a synthetic active division.") { app in
            await StateCatalog.turn(.landscapeRight)
            StateCatalog.duoColumn(app, left: false)
            let size = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.bounds.size ?? .zero
            app.workspace.reservations.divisions = [CGRect(x: size.width / 2, y: 0, width: 20, height: size.height)]
        },
        NamedState("duo.portrait", "Portrait, sides respected", "The window's safe area at left and right clears the chrome.") { _ in
            await StateCatalog.turn(.portrait)
        },
        NamedState("duo.landscape", "Landscape, sides respected", "The same, turned.") { _ in
            await StateCatalog.turn(.landscapeRight)
        },
        NamedState("duo.landscape.left", "Landscape, other way", "Turned the other way: the status column moves to the other side with the same window size.") { _ in
            await StateCatalog.turn(.landscapeLeft)
        },
        NamedState("duo.landscape.left.before", "Landscape, other way, before the fix", "Sides ignored, as 0.1.21 drew it.") { _ in
            ChromeGeometry.sidesDisabled = true
            await StateCatalog.turn(.landscapeLeft)
        },
        NamedState("duo.portrait.before", "Portrait, before the fix", "Sides ignored, as 0.1.21 drew it.") { _ in
            ChromeGeometry.sidesDisabled = true
            await StateCatalog.turn(.portrait)
        },
        NamedState("duo.landscape.before", "Landscape, before the fix", "Sides ignored, as 0.1.21 drew it.") { _ in
            ChromeGeometry.sidesDisabled = true
            await StateCatalog.turn(.landscapeRight)
        },
        NamedState("duo.spaces", "Spaces, portrait", "The head clears the camera, the status bar steps aside.") { app in
            FieldModel.sheetInTests = true
            await StateCatalog.turn(.portrait)
            app.field.openNewTab(privately: false)
            try? await Task.sleep(for: .milliseconds(600))
            app.field.expandSheet()
        },
        NamedState("duo.wide", "No header", "The unfolded layout on the cover: page content inside the safe area, the rail below system occlusions.") { _ in
            BrowserWorkspace.regularForced = true
            await StateCatalog.turn(.landscapeLeft)
        },
        NamedState("duo.wide.panel", "No header, spaces", "The spaces' column: the head high, the gear and a round + at its foot.") { app in
            FieldModel.sheetInTests = true
            BrowserWorkspace.regularForced = true
            await StateCatalog.turn(.landscapeLeft)
            app.field.openSpaces()
        },
        NamedState("duo.wide.search", "No header, search", "The centered search card over the page.") { app in
            BrowserWorkspace.regularForced = true
            await StateCatalog.turn(.landscapeLeft)
            app.surfaces.openField(.address)
        },
        NamedState("workspace.spaces", "Spaces sidebar", "The same spaces screen in a bounded sidebar.") { app in
            app.field.openSpacesInPlace()
        },
    ]
}

extension StateCatalog {
    /// Rotation fixtures keep a hardware column instead of retaining the
    /// ordinary simulator's cutout cancellation from its launch orientation.
    @MainActor static var rotatingColumnLeft: Bool?

    @MainActor private static var duoRetirement: DuoRetirementProbe?

    @MainActor private static func duoRotation(_ app: AppModel, left: Bool) async {
        await turn(.portrait)
        rotatingColumnLeft = left
        duoColumn(app, left: left)
        if let previous = app.browser.tab { TabStack.of(app).touch(previous.id, in: app.browser.spaceID) }
        let tab = Tab(id: "duo-ruler", title: "Viewport ruler", site: "Viewport ruler", icon: "globe",
                      url: app.fixturesEnabled ? nil : LaunchOptions.current.initialURL?.absoluteString,
                      page: "duo-ruler")
        app.browser.open(tab, deduplicate: false)
        TabStack.of(app).touch(tab.id, in: app.browser.spaceID)
        if !app.fixturesEnabled,
           let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.keyWindow {
            duoRetirement = DuoRetirementProbe(app: app, window: window, page: app.pages.activate(tab))
        }
    }

    /// Synthetic columns exercise the same geometry on the ordinary simulator.
    /// Cancel its symmetric landscape cutout insets before reserving one side.
    @MainActor static func duoColumn(_ app: AppModel, left: Bool, activity: Bool = false) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.keyWindow else { return }
        let safe = window.safeAreaInsets
        ChromeGeometry.extraSides = .init(left: (left ? 84 : 0) - safe.left, right: (left ? 0 : 84) - safe.right)
        app.workspace.reservations = .init(
            occlusions: [CGRect(x: left ? 0 : window.bounds.width - 84, y: 0, width: 84, height: activity ? 190 : 150)],
            statusBarHeight: 22)
    }

    /// Asks the scene for an orientation and waits for the window to follow.
    @MainActor static func turn(_ mask: UIInterfaceOrientationMask) async {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        try? await Task.sleep(for: .seconds(1.5))
    }
}

/// Replays the late portrait-host callback through the real pool after each
/// rotation. Only the explicit live named state installs this hidden host.
@MainActor
private final class DuoRetirementProbe: NSObject {
    private struct Signature: Equatable {
        let size: CGSize
        let orientation: Int
        let left: Bool
    }
    private weak var app: AppModel?
    private weak var window: UIWindow?
    private weak var page: WKWebView?
    private let retiring: PageContainer
    private let portraitSize: CGSize
    private var link: CADisplayLink?
    private var last: Signature?
    private var sequence = 0

    init(app: AppModel, window: UIWindow, page: WKWebView) {
        self.app = app
        self.window = window
        self.page = page
        retiring = PageContainer(frame: window.bounds)
        portraitSize = window.bounds.size
        super.init()
        retiring.isHidden = true
        retiring.isUserInteractionEnabled = false
        retiring.fixturesEnabled = false
        retiring.pool = app.pages
        window.addSubview(retiring)
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.preferredFramesPerSecond = 4
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func sample() {
        guard let app, let window, let page else {
            link?.invalidate()
            retiring.removeFromSuperview()
            return
        }
        guard UIApplication.shared.applicationState == .active, page.window === window,
              app.browser.tab?.id == "duo-ruler", app.pages.painted.contains("duo-ruler"),
              !FirstLaunch.shows(app), app.surfaces.field == nil,
              !app.surfaces.coversChrome, TabStack.of(app).gallery == nil else { return }
        let signature = Signature(size: window.bounds.size,
                                  orientation: window.windowScene?.interfaceOrientation.rawValue ?? 0,
                                  left: app.workspace.leadingRail)
        guard signature != last else { return }
        last = signature
        // Let the new host finish its rotation before the retiring host speaks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.last == signature, let app = self.app,
                  let window = self.window, let page = self.page else { return }
            self.retiring.frame = CGRect(origin: .zero, size: self.portraitSize)
            self.retiring.updateViewport()
            let frame = page.convert(page.bounds, to: window)
            self.sequence += 1
            let record: [String: Any] = [
                "sequence": self.sequence, "orientation": signature.orientation, "columnLeft": signature.left,
                "windowWidth": Double(window.bounds.width), "windowHeight": Double(window.bounds.height),
                "viewX": Double(frame.minX), "viewY": Double(frame.minY),
                "viewWidth": Double(frame.width), "viewHeight": Double(frame.height),
                "leftInset": Double(page.obscuredContentInsets.left), "rightInset": Double(page.obscuredContentInsets.right),
                "leftIndicator": Double(page.scrollView.verticalScrollIndicatorInsets.left),
                "rightIndicator": Double(page.scrollView.verticalScrollIndicatorInsets.right),
                "indicatorsAdjusted": page.scrollView.automaticallyAdjustsScrollIndicatorInsets,
                "liveProfile": !app.pages.fixturesEnabled, "retiringWidth": Double(self.portraitSize.width),
            ]
            if let folder = StateProbe.readyDirectory,
               let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("duo-retirement.json"), options: .atomic)
            }
        }
    }
}

extension StateCatalog {
    /// Site Controls in its popover, as its door in the sidebar or band opens it.
    @MainActor static func openSiteControls(_ app: AppModel) {
        app.openPageMenu()
        app.pageMenu.shown = true
        app.pageMenu.page = .site
    }
}
