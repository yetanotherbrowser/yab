import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// The page menu's rules: zoom and desktop mode remembered per site (private
/// tabs apart, in memory), what a site asked for, Copy Link's toast at the
/// bottom, the field's "On This Page" row, and the menu staying mounted
/// until its row has landed back on the plate.
@MainActor
final class PageMenuTests: XCTestCase {
    private var app: AppModel!

    override func setUp() async throws {
        Motion.disabled = true
        app = AppModel(world: try World.load(named: "mira"))
        app.surfaces.toastsStay = true
    }

    // MARK: - per-site memory

    func testZoomIsRememberedPerSiteAndKeptApartForPrivate() throws {
        let suite = "yab.tests.siteSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SiteSettings(defaults: defaults)
        settings.setZoom(1.2, for: "www.Linear.app", isPrivate: false)
        XCTAssertEqual(settings.zoom("linear.app", isPrivate: false), 1.2, "www and case are the same site")
        XCTAssertEqual(settings.zoom("figma.com", isPrivate: false), 1, "another site keeps 100 %")
        XCTAssertEqual(settings.zoom("linear.app", isPrivate: true), 1, "private browsing never reads the ordinary memory")
        settings.setZoom(0.8, for: "linear.app", isPrivate: true)
        XCTAssertEqual(settings.zoom("linear.app", isPrivate: false), 1.2, "nor writes it")

        let again = SiteSettings(defaults: defaults)
        XCTAssertEqual(again.zoom("linear.app", isPrivate: false), 1.2, "ordinary sites outlive the app")
        XCTAssertEqual(again.zoom("linear.app", isPrivate: true), 1, "private ones don't")

        settings.setZoom(1, for: "linear.app", isPrivate: false)
        XCTAssertNil(defaults.data(forKey: "yab.siteSettings").flatMap { try? JSONDecoder().decode([String: SiteSettings.Site].self, from: $0) }?["linear.app"],
                     "100 % again is nothing to remember")
    }

    func testZoomStepsAndTheMenusStepper() throws {
        XCTAssertEqual(SiteSettings.step(1, by: 1), 1.1)
        XCTAssertEqual(SiteSettings.step(1, by: -1), 0.9)
        XCTAssertNil(SiteSettings.step(3, by: 1))
        XCTAssertNil(SiteSettings.step(0.5, by: -1))
        XCTAssertEqual(SiteSettings.percent(1.1), 110)

        XCTAssertEqual(app.pageZoom, 1)
        app.pageMenuZoom(1)
        app.pageMenuZoom(1)
        XCTAssertEqual(app.pageZoom, 1.2, accuracy: 0.001)
        let host = app.siteHost(of: try XCTUnwrap(app.browser.tab))
        XCTAssertEqual(host, "figma.com")
        XCTAssertEqual(app.siteSettings.zoom("figma.com", isPrivate: false), 1.2, accuracy: 0.001)
        app.pageMenuZoom(0)
        XCTAssertEqual(app.pageZoom, 1, "a tap on the percent goes back to 100 %")
        XCTAssertTrue(Haptics.played.suffix(3).map(\.reason).contains(Haptics.Reason.zoomReset))
    }

    func testRequestDesktopSiteTogglesForTheSite() throws {
        app.siteSettings.prefersDesktop = false
        XCTAssertFalse(app.pageIsDesktop)
        app.pageMenuDesktop()
        XCTAssertTrue(app.pageIsDesktop)
        XCTAssertTrue(app.siteSettings.desktop("figma.com", isPrivate: false))
        app.pageMenuDesktop()
        XCTAssertFalse(app.pageIsDesktop, "Request Mobile Site takes it back")
        XCTAssertFalse(app.siteSettings.desktop("figma.com", isPrivate: false))
    }

    /// An iPad left to its own choice gets Safari's: mobile in a narrow pane.
    /// The switch reads that page, not the choice: Off, and its first tap
    /// asks for the desktop site, rather than for the mobile one it shows.
    func testTheDesktopSwitchReadsANarrowPanesMobilePage() async throws {
        app.siteSettings.prefersDesktop = true
        let tab = try XCTUnwrap(app.browser.tab)
        let host = app.siteHost(of: tab)
        XCTAssertEqual(app.siteSettings.version(host, isPrivate: false), .automatic)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        defer { window.isHidden = true }
        let view = app.pages.activate(tab)
        view.frame = window.bounds
        window.addSubview(view)
        await app.pages.waitUntilPainted(tab.id)
        let end = Date().addingTimeInterval(10)
        while app.pages.state(for: tab.id).isLoading, Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(app.pageIsDesktop, "a narrow pane's page is the mobile site")
        app.pageMenuDesktop()
        XCTAssertEqual(app.siteSettings.version(host, isPrivate: false), .desktop, "the first tap asks for the desktop site")
        XCTAssertTrue(app.pageIsDesktop)
    }

    /// As Safari on iPad: desktop sites unless a site is asked for as a mobile one.
    func testAnIPadAsksForDesktopSitesUnlessTold() throws {
        let settings = SiteSettings(defaults: nil, prefersDesktop: true)
        XCTAssertTrue(settings.desktop("google.com", isPrivate: false))
        XCTAssertEqual(settings.contentMode("google.com", isPrivate: false), .recommended)
        settings.setDesktop(false, for: "google.com", isPrivate: false)
        XCTAssertFalse(settings.desktop("google.com", isPrivate: false))
        XCTAssertEqual(settings.contentMode("google.com", isPrivate: false), .mobile)
        XCTAssertTrue(settings.desktop("figma.com", isPrivate: false), "only that site")
        settings.setDesktop(true, for: "google.com", isPrivate: false)
        XCTAssertTrue(settings.desktop("google.com", isPrivate: false))
        // Asked for, it is the desktop site even in a pane narrow enough
        // for WebKit's recommended mode to choose the mobile one.
        XCTAssertEqual(settings.version("google.com", isPrivate: false), .desktop)
        XCTAssertEqual(settings.contentMode("google.com", isPrivate: false), .desktop)
        XCTAssertEqual(settings.contentMode("figma.com", isPrivate: false), .recommended, "a site never asked stays WebKit's")

        let phone = SiteSettings(defaults: nil, prefersDesktop: false)
        XCTAssertEqual(phone.contentMode("google.com", isPrivate: false), .mobile)
        phone.setDesktop(true, for: "google.com", isPrivate: false)
        XCTAssertEqual(phone.contentMode("google.com", isPrivate: false), .desktop)
        phone.setDesktop(false, for: "google.com", isPrivate: false)
        XCTAssertEqual(phone.contentMode("google.com", isPrivate: false), .mobile)
        XCTAssertTrue(phone.site("google.com", isPrivate: false).isEmpty, "an iPhone's mobile is its default, nothing kept")
    }

    /// One choice per site, default, desktop or mobile: each device reads it
    /// against its own default (iPad: WebKit's recommended, iPhone: mobile).
    func testASiteIsAskedForByItsOneChoiceOnEachDevice() {
        let pad = SiteSettings(defaults: nil, prefersDesktop: true)
        let phone = SiteSettings(defaults: nil, prefersDesktop: false)
        XCTAssertEqual(pad.version("google.com", isPrivate: false), .automatic)
        XCTAssertEqual(pad.contentMode("google.com", isPrivate: false), .recommended)
        XCTAssertEqual(phone.contentMode("google.com", isPrivate: false), .mobile)
        for settings in [pad, phone] {
            settings.setVersion(.mobile, for: "google.com", isPrivate: false)
            XCTAssertEqual(settings.contentMode("google.com", isPrivate: false), .mobile)
            XCTAssertFalse(settings.desktop("google.com", isPrivate: false))
            settings.setVersion(.desktop, for: "google.com", isPrivate: false)
            XCTAssertEqual(settings.contentMode("google.com", isPrivate: false), .desktop)
            XCTAssertTrue(settings.desktop("google.com", isPrivate: false))
        }
    }

    /// Settings saved before the one choice (`desktop`, `mobile`) load as it.
    func testSavedDesktopAndMobileSitesLoadAsTheirChoice() throws {
        let suite = "yab.tests.siteVersion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = #"""
        {"figma.com": {"zoom": 1.2, "desktop": true, "permissions": []},
         "google.com": {"zoom": 1, "desktop": false, "mobile": true, "permissions": []},
         "linear.app": {"zoom": 1.1, "desktop": false, "permissions": []}}
        """#
        defaults.set(Data(saved.utf8), forKey: "yab.siteSettings")
        let settings = SiteSettings(defaults: defaults, prefersDesktop: true)
        XCTAssertEqual(settings.version("figma.com", isPrivate: false), .desktop)
        XCTAssertEqual(settings.zoom("figma.com", isPrivate: false), 1.2, accuracy: 0.001)
        XCTAssertEqual(settings.version("google.com", isPrivate: false), .mobile)
        XCTAssertEqual(settings.version("linear.app", isPrivate: false), .automatic)
        settings.setZoom(1.3, for: "figma.com", isPrivate: false)
        let again = SiteSettings(defaults: defaults, prefersDesktop: true)
        XCTAssertEqual(again.version("figma.com", isPrivate: false), .desktop, "saved again in the new shape")
        XCTAssertEqual(again.version("google.com", isPrivate: false), .mobile)
    }

    func testWhatASiteAskedForIsSaidInAWordAndForgotten() {
        let settings = SiteSettings(defaults: nil)
        XCTAssertEqual(settings.asked([.camera], host: "meet.example", isPrivate: false), .prompt, "first time: iOS asks")
        XCTAssertEqual(settings.permissions("meet.example", isPrivate: false).map(\.1), [.ask])
        settings.setDecision(.allowed, .camera, for: "meet.example", isPrivate: false)
        XCTAssertEqual(settings.asked([.camera], host: "meet.example", isPrivate: false), .grant)
        XCTAssertEqual(settings.asked([.camera, .microphone], host: "meet.example", isPrivate: false), .prompt,
                       "the microphone is new: asked")
        settings.setDecision(.off, .microphone, for: "meet.example", isPrivate: false)
        XCTAssertEqual(settings.asked([.camera, .microphone], host: "meet.example", isPrivate: false), .deny)
        settings.forget(.microphone, for: "meet.example", isPrivate: false)
        XCTAssertEqual(settings.permissions("meet.example", isPrivate: false).map(\.0), [.camera])
        XCTAssertTrue(settings.permissions("other.example", isPrivate: false).isEmpty, "nothing asked, no section")
    }

    // MARK: - the menu

    func testTheMenuStaysMountedUntilItLandsAndCopyLinkTicksInPlace() {
        app.openPageMenu()
        XCTAssertEqual(app.surfaces.menu, .plate)
        app.pageMenu.shown = true
        app.closePageMenu()
        XCTAssertNil(app.surfaces.menu, "with motion off it lands at once")
        XCTAssertFalse(app.pageMenu.shown)

        app.openPageMenu()
        app.pageMenu.shown = true
        app.pageMenuCopyLink()
        // As the Mac's link: a tick where it is, the menu stays, no toast.
        XCTAssertEqual(app.surfaces.menu, .plate)
        XCTAssertTrue(app.pageMenu.shown)
        XCTAssertEqual(app.pageMenu.copies, 1)
        XCTAssertNil(app.surfaces.toast)
        XCTAssertEqual(Haptics.played.last?.reason, Haptics.Reason.linkCopied)
    }

    /// The named state of a private tab's menu shows the menu, as page.6
    /// does for an ordinary page, with the whole app drawn: it only mounted
    /// the menu, in the same turn as the private tab came in front, and the
    /// chrome put it away for the new tab, so the shot had no menu in it.
    func testThePrivateTabsMenuStateShowsTheMenu() async throws {
        let welcomed = SettingsStore.shared.welcomed
        SettingsStore.shared.welcomed = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: RootView().environment(app))
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer {
            window.isHidden = true; window.rootViewController = nil
            previous?.makeKey()
            SettingsStore.shared.welcomed = welcomed
        }
        try await Task.sleep(for: .milliseconds(300))
        let state = try XCTUnwrap(StateCatalog.named("fieldcheck.3"))
        await state.apply(app)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(app.browser.tab?.isPrivate, true, "over a private tab")
        XCTAssertEqual(app.surfaces.menu, .plate, "the menu stays open over the private tab")
        XCTAssertTrue(app.pageMenu.shown, "the menu is up, not only mounted")
        XCTAssertEqual(app.pageMenu.page, .menu)
    }

    func testKeepFromTheMenuKeepsAndUnkeeps() throws {
        let id = try XCTUnwrap(app.browser.tab?.id)
        let wasKept = app.pageIsKept
        app.pageMenuKeep()
        XCTAssertNotEqual(app.pageIsKept, wasKept)
        XCTAssertEqual(app.browser.tab?.id, id, "the page stays in front")
        app.pageMenuKeep()
        XCTAssertEqual(app.pageIsKept, wasKept)
    }

    func testOpenOnMacAnswersInItsRow() {
        app.openPageMenu()
        app.pageMenuOpenOnMac()
        XCTAssertTrue(app.pageMenu.openedOnMac)
        XCTAssertNil(app.surfaces.toast, "the row says it, no toast")
    }

    // MARK: - On This Page

    func testTheFieldOffersOnThisPageWhenThePageHoldsTheWords() {
        app.surfaces.openField(.address)
        app.field.typed("hours")
        XCTAssertFalse(app.fieldRows.contains { $0.action == .findOnPage }, "not counted yet")
        app.field.onThisPage = ("hours", 3)
        let row = app.fieldRows.last
        XCTAssertEqual(row?.action, .findOnPage, "last, under the rest")
        XCTAssertEqual(row?.title, "On This Page · 3 matches")
        XCTAssertNotEqual(app.fieldRows.first?.action, .findOnPage, "never the key's row")
        app.field.onThisPage = ("hours", 1)
        XCTAssertEqual(app.fieldRows.last?.title, "On This Page · 1 match")
        app.field.typed("hours of")
        XCTAssertFalse(app.fieldRows.contains { $0.action == .findOnPage }, "a count of other words isn't shown")
    }

    func testOnThisPageWorksOverAPrivateTabToo() {
        app.openPrivately(PageFixtures.search("gift ideas for jonas"))
        app.surfaces.openField(.address)
        app.field.typed("gift")
        app.field.onThisPage = ("gift", 2)
        XCTAssertEqual(app.fieldRows.map(\.action), [.search, .findOnPage])
    }
}
