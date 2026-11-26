import Observation
import UIKit
import XCTest
@testable import YabPhone

@MainActor
final class PrivateLockTests: XCTestCase {
    private final class Authentication: PrivateAuthenticating {
        var completions: [@MainActor (PrivateAuthenticationResult) -> Void] = []
        var invalidations = 0
        func authenticate(_ completion: @escaping @MainActor (PrivateAuthenticationResult) -> Void) {
            completions.append(completion)
        }
        func invalidate() { invalidations += 1 }
        func finish(_ result: PrivateAuthenticationResult, attempt: Int? = nil) {
            completions[attempt ?? (completions.count - 1)](result)
        }
    }

    @Observable fileprivate final class Preference { var enabled = true }

    private func live(_ authentication: Authentication, preference: Preference = Preference(),
                      profile: BrowserProfile? = nil) -> AppModel {
        let ordinary = PageFixtures.liveTab(for: URL(string: "http://127.0.0.1/public")!, id: "ordinary")
        let secret = PageFixtures.liveTab(for: URL(string: "http://127.0.0.1/secret")!, id: "secret", isPrivate: true,
                                         title: "Secret document")
        let world = World(name: "private-lock-test", space: "public", spaces: [
            Space(id: "public", name: "Public", emoji: "", tint: RGB(238, 233, 226), today: [ordinary], current: ordinary.id),
            Space(id: "private", name: "Private", emoji: "", tint: RGB(44, 42, 52), pins: [secret], current: secret.id, isPrivate: true)
        ], mac: World.Mac(joined: false))
        return AppModel(world: world, fixturesEnabled: false, profile: profile,
                        privateAuthentication: authentication, privateLockEnabled: { preference.enabled })
    }

    func testExternalLinkArrivingBeforeActiveInPrivateWithoutAuthenticationOpensOnReturn() {
        let auth = Authentication()
        let preference = Preference()
        preference.enabled = false
        let app = live(auth, preference: preference)
        app.browser.select("secret")
        app.privateLock.willResignActive()
        app.privateLock.didEnterBackground()
        let requested = URL(string: "http://127.0.0.1/external")!

        app.openLink(requested)
        XCTAssertEqual(app.browser.tab?.id, "secret", "inactive Private stays covered")
        app.privateLock.didBecomeActive()

        XCTAssertEqual(app.browser.tab?.navigationURL, requested, "the first link must survive the return to an active scene")
        XCTAssertTrue(app.browser.tab?.isPrivate == true)
        XCTAssertEqual(auth.completions.count, 0, "authentication is disabled")
    }

    func testPrivateSelectionWaitsForAuthenticationAndLeavingRetainsItsTabs() {
        let auth = Authentication()
        let app = live(auth)
        app.browser.select("secret")
        XCTAssertEqual(app.browser.spaceID, "public")
        XCTAssertEqual(app.browser.tab?.id, "ordinary")
        XCTAssertTrue(app.privateLock.presentsPrompt)
        XCTAssertTrue(app.privateContentBlocked == false, "the public page is still selected behind the opaque prompt")
        XCTAssertFalse(app.privateLock.mayReveal)
        XCTAssertEqual(auth.completions.count, 1)
        auth.finish(.unlocked)
        XCTAssertEqual(app.browser.spaceID, "private")
        XCTAssertEqual(app.browser.tab?.id, "secret")
        XCTAssertFalse(app.privateContentBlocked)
        app.browser.showSpace("public")
        XCTAssertFalse(app.privateLock.mayReveal)
        XCTAssertEqual(app.browser.tab("secret")?.title, "Secret document", "exit locks, rather than closes, Private")
        app.browser.showSpace("private")
        XCTAssertEqual(app.browser.spaceID, "public")
        XCTAssertEqual(auth.completions.count, 2)
        auth.finish(.unlocked)
        XCTAssertEqual(app.browser.tab?.id, "secret")
    }

    func testCancelledFirstEntryRetryAndStaleSuccessCannotRevealPrivate() {
        let auth = Authentication()
        let app = live(auth)
        app.browser.select("secret")
        auth.finish(.cancelled)
        XCTAssertEqual(app.browser.spaceID, "public")
        XCTAssertFalse(app.privateLock.mayReveal)
        XCTAssertTrue(app.privateLock.presentsPrompt)
        app.privateLock.unlock()
        auth.finish(.unlocked, attempt: 0)
        XCTAssertEqual(app.browser.spaceID, "public", "retired callbacks cannot select the requested tab")
        XCTAssertFalse(app.privateLock.mayReveal)
        auth.finish(.unlocked, attempt: 1)
        XCTAssertEqual(app.browser.tab?.id, "secret")
    }

    func testUnavailableDeviceAndFailedAttemptStayLockedWithAnExplicitBackRoute() {
        for result in [PrivateAuthenticationResult.unavailable, .failed] {
            let auth = Authentication()
            let app = live(auth)
            app.browser.showSpace("private")
            auth.finish(result)
            guard case let .failed(message) = app.privateLock.phase else { return XCTFail("an error must remain visible") }
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(app.privateLock.mayReveal)
            app.leaveLockedPrivate()
            auth.finish(.unlocked)
            XCTAssertFalse(app.privateLock.presentsPrompt)
            XCTAssertEqual(app.browser.tab?.id, "ordinary")
            XCTAssertEqual(app.browser.tab("secret")?.id, "secret")
        }
    }

    func testAuthenticationInactiveDoesNotLoopAndSuccessWaitsForActiveScene() {
        let auth = Authentication()
        let app = live(auth)
        app.browser.select("secret")
        app.privateLock.willResignActive()
        auth.finish(.unlocked)
        XCTAssertFalse(app.privateLock.mayReveal)
        XCTAssertEqual(app.browser.spaceID, "public")
        app.privateLock.didBecomeActive()
        XCTAssertTrue(app.privateLock.mayReveal)
        XCTAssertEqual(app.browser.tab?.id, "secret")
        XCTAssertEqual(auth.completions.count, 1, "the system authentication prompt must not cause another prompt")
    }

    func testSuccessUnderTheSystemSheetIsKnownAtOnceButRevealsNothingUntilActive() {
        let auth = Authentication()
        let app = live(auth)
        app.browser.select("secret")
        app.privateLock.willResignActive()
        XCTAssertFalse(app.privateLock.isVerified)
        let seen = expectation(description: "verification observed before the scene is active")
        withObservationTracking { _ = app.privateLock.isVerified } onChange: { seen.fulfill() }
        auth.finish(.unlocked)
        wait(for: [seen], timeout: 1)
        XCTAssertTrue(app.privateLock.isVerified, "the lock can start opening under the system's own sheet")
        XCTAssertFalse(app.privateLock.mayReveal)
        XCTAssertEqual(app.browser.spaceID, "public", "nothing private is entered until the scene is active")
        app.privateLock.didBecomeActive()
        XCTAssertTrue(app.privateLock.isVerified)
        XCTAssertTrue(app.privateLock.mayReveal)
        XCTAssertEqual(app.browser.tab?.id, "secret")
        XCTAssertFalse(app.privateContentBlocked)
    }

    func testLeavingBeforeTheSceneIsActiveWithdrawsTheEarlySuccess() {
        let auth = Authentication()
        let app = live(auth)
        app.browser.select("secret")
        app.privateLock.willResignActive()
        auth.finish(.unlocked)
        XCTAssertTrue(app.privateLock.isVerified)
        app.privateLock.didEnterBackground()
        XCTAssertFalse(app.privateLock.isVerified, "the lock closes again; nothing was unlocked")
        app.privateLock.didBecomeActive()
        XCTAssertFalse(app.privateLock.isVerified)
        XCTAssertFalse(app.privateLock.mayReveal)
    }

    func testBackgroundRetiresPendingSuccessAndAlreadySelectedPrivateRequiresAnotherUnlock() {
        let auth = Authentication()
        let app = live(auth)
        app.browser.select("secret")
        app.privateLock.willResignActive()
        app.privateLock.didEnterBackground()
        auth.finish(.unlocked)
        app.privateLock.didBecomeActive()
        XCTAssertEqual(app.browser.spaceID, "public")
        XCTAssertFalse(app.privateLock.mayReveal)
        app.browser.select("secret")
        auth.finish(.unlocked)
        app.privateLock.willResignActive()
        app.privateLock.didEnterBackground()
        app.privateLock.didBecomeActive()
        XCTAssertEqual(app.browser.tab?.id, "secret", "a background transition must preserve the selected private tab in memory")
        XCTAssertFalse(app.privateLock.presentsPrompt, "this is a relock, not a pending first entry")
        XCTAssertTrue(app.privateContentBlocked)
        app.privateLock.unlock()
        auth.finish(.cancelled)
        XCTAssertTrue(app.privateContentBlocked)
        app.privateLock.unlock()
        auth.finish(.unlocked)
        XCTAssertFalse(app.privateContentBlocked)
        XCTAssertEqual(app.browser.tab?.id, "secret")
    }

    func testReturningToPublicCancelsPendingEntryEvenIfPublicWasAlreadySelected() {
        let auth = Authentication()
        let app = live(auth)
        app.browser.showSpace("private")
        app.browser.showSpace("public")
        auth.finish(.unlocked)
        XCTAssertEqual(app.browser.spaceID, "public")
        XCTAssertFalse(app.privateLock.mayReveal)
    }

    func testDisabledPreferenceAppliesAndEnablingHidesBeforeObservationCallback() {
        let auth = Authentication()
        let preference = Preference()
        preference.enabled = false
        let app = live(auth, preference: preference)
        app.browser.select("secret")
        XCTAssertEqual(app.browser.tab?.id, "secret")
        XCTAssertTrue(auth.completions.isEmpty)
        preference.enabled = true
        XCTAssertTrue(app.privateContentBlocked, "enable must hide immediately, before the asynchronous observation callback")
        app.privateLock.preferenceChanged()
        app.privateLock.unlock()
        auth.finish(.unlocked)
        XCTAssertFalse(app.privateContentBlocked)
        preference.enabled = false
        app.privateLock.preferenceChanged()
        XCTAssertTrue(app.privateLock.mayReveal)
        app.privateLock.willResignActive()
        XCTAssertFalse(app.privateLock.mayReveal, "even with the preference off, the inactive app snapshot has a curtain")
        app.privateLock.didBecomeActive()
        XCTAssertTrue(app.privateLock.mayReveal)
        XCTAssertEqual(auth.completions.count, 1)
    }

    func testPrivateFieldAndPagingNeighborsAreBlockedBeforeTheirPublicRootCanDrawThem() {
        let auth = Authentication()
        let app = live(auth)
        // A private New Tab shows Private's own lock page and nothing of
        // Private, so it is not covered.
        app.surfaces.openField(.newTab)
        app.field.setPrivate(true)
        XCTAssertFalse(app.privateContentBlocked, "Private's New Tab draws its own lock, never private content")
        app.surfaces.closeField()
        app.field.endPrivate()
        // The address field over a private page is covered with the page.
        app.browser.select("secret")
        auth.finish(.unlocked)
        app.surfaces.openField(.address)
        XCTAssertFalse(app.privateContentBlocked)
        app.privateLock.leavePrivate()
        XCTAssertTrue(app.privateContentBlocked)
        app.leaveLockedPrivate()
        app.surfaces.pageSwipe = PageSwipe(offset: 10, before: app.browser.tab("secret"), after: nil, newTab: false)
        XCTAssertTrue(app.privateContentBlocked, "retained neighbor snapshots cannot bypass the root gate")
    }

    func testPrivateChatOriginRequiresEntryButItsClosedRetainedIDDoesNotTrapPublic() throws {
        let auth = Authentication()
        let app = live(auth)
        let chat = try XCTUnwrap(World.load(named: "mira").chats.first)
        app.chats.add(chat, isPrivate: true)
        app.openChat(chat.id)
        XCTAssertEqual(app.browser.spaceID, "public")
        XCTAssertFalse(app.chatSheet.shown)
        XCTAssertTrue(app.privateLock.presentsPrompt)
        auth.finish(.unlocked)
        XCTAssertEqual(app.browser.spaceID, "private")
        XCTAssertTrue(app.chatSheet.shown)
        app.hideSheet()
        app.browser.showSpace("public")
        XCTAssertFalse(app.privateContentBlocked, "a hidden retained private chat ID is not a rendered surface")
        XCTAssertFalse(app.chats.visibleChats.contains { $0.id == chat.id })
        app.surfaces.menu = .chat(chat.id)
        XCTAssertTrue(app.privateContentBlocked, "a raw private More menu must not bypass the gate")
        app.leaveLockedPrivate()
        XCTAssertFalse(app.privateContentBlocked)
    }

    func testRetainedPrivateRenameAlertIsBlockedWithoutTrappingAClosedChat() throws {
        let app = live(Authentication())
        let chat = try XCTUnwrap(World.load(named: "mira").chats.first)
        app.chats.add(chat, isPrivate: true)
        app.chatSheet.chatID = chat.id
        app.chatSheet.shown = false
        XCTAssertFalse(app.privateContentBlocked)
        app.chatSheet.renaming = chat.id
        app.chatSheet.renameText = "private renamed title"
        XCTAssertTrue(app.privateContentBlocked, "the native Rename alert is rendered independently of the closed tray")
        app.leaveLockedPrivate()
        XCTAssertNil(app.chatSheet.renaming)
        XCTAssertEqual(app.chatSheet.renameText, "")
        XCTAssertFalse(app.privateContentBlocked)
        XCTAssertEqual(app.browser.spaceID, "public")
        XCTAssertEqual(app.chats.chat(chat.id)?.title, chat.title, "Back cancels the alert without saving a private draft title")
    }

    func testLockingRetainsPrivateMemoryButProfileContainsNoPrivateURLTitleOrNavigation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateLockTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = BrowserProfile(folder: directory)
        let auth = Authentication()
        let app = live(auth, profile: profile)
        app.browser.select("secret")
        auth.finish(.unlocked)
        profile.capture(app.browser)
        profile.navigationChanged("secret", BrowserNavigation(entries: [.init(url: "http://127.0.0.1/secret", title: "Secret document", scrollY: 123)], index: 0))
        profile.recordVisit(try XCTUnwrap(app.browser.tab("secret")))
        app.privateLock.didEnterBackground()
        await app.flushProfile()
        XCTAssertEqual(app.browser.tab("secret")?.id, "secret")
        let data = try String(contentsOf: directory.appendingPathComponent("profile.json"), encoding: .utf8)
        XCTAssertFalse(data.contains("/secret"))
        XCTAssertFalse(data.contains("Secret document"))
        XCTAssertFalse(data.contains("\"secret\""))
        let restored = BrowserProfile(folder: directory)
        XCTAssertTrue(restored.navigation.isEmpty)
        XCTAssertEqual(restored.snapshot.spaces.map(\.id), ["public"])
    }

    func testInactiveUIKitCurtainResignsKeyboardAndCoversTheWholeWindowSynchronously() {
        let app = live(Authentication())
        let controller = RootController(app: app)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        let input = UITextField(frame: CGRect(x: 10, y: 200, width: 200, height: 44))
        input.text = "private draft"
        controller.view.addSubview(input)
        XCTAssertTrue(input.becomeFirstResponder())
        controller.setInactivePrivacyCover(true)
        XCTAssertFalse(input.isFirstResponder)
        let curtain = window.subviews.last
        XCTAssertEqual(curtain?.accessibilityIdentifier, "private.curtain")
        XCTAssertEqual(curtain?.frame, window.bounds)
        XCTAssertFalse(curtain?.isHidden ?? true)
        XCTAssertTrue(controller.view.accessibilityElementsHidden)
        controller.setInactivePrivacyCover(false)
        XCTAssertTrue(curtain?.isHidden ?? false)
    }

    /// A panel UIKit presents over the page (Save as PDF's share sheet, the
    /// print panel, the document viewer) stands above RootController's own
    /// view: the curtain covers it too before the system's snapshot.
    func testInactiveCurtainCoversWhatIsPresentedOverThePage() throws {
        let app = live(Authentication())
        let controller = RootController(app: app)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previous = scene?.windows.first(where: \.isKeyWindow)
        let window = try UIWindow(windowScene: XCTUnwrap(scene))
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { controller.dismiss(animated: false); window.isHidden = true; previous?.makeKey() }
        let panel = UIViewController()
        panel.view.backgroundColor = .red
        panel.modalPresentationStyle = .fullScreen
        controller.present(panel, animated: false)
        let end = Date().addingTimeInterval(5)
        while panel.view.window == nil || panel.isBeingPresented, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertFalse(panel.isBeingPresented, "the panel is up")
        let presented = try XCTUnwrap(window.subviews.first { panel.view.isDescendant(of: $0) }, "the panel is in the window")
        controller.setInactivePrivacyCover(true)
        let curtain = try XCTUnwrap(window.subviews.last)
        XCTAssertEqual(curtain.accessibilityIdentifier, "private.curtain", "the curtain is above the panel")
        XCTAssertGreaterThan(window.subviews.firstIndex(of: curtain) ?? -1, window.subviews.firstIndex(of: presented) ?? Int.max)
        XCTAssertEqual(curtain.frame, window.bounds)
        XCTAssertFalse(curtain.isHidden)
        XCTAssertTrue(curtain.accessibilityViewIsModal, "VoiceOver reads nothing under it")
        controller.setInactivePrivacyCover(false)
        XCTAssertTrue(curtain.isHidden)
    }

    func testExplicitDebugAuthenticationRequiresAnIsolatedProfileAndFlag() {
        let flag = ["Yab", "-YabPrivateLockTestAuthentication", "allow,cancel"]
        XCTAssertNil(PrivateLock.testingConfiguration(profileDirectory: nil, arguments: flag).authentication)
        XCTAssertNil(PrivateLock.testingConfiguration(profileDirectory: "/Users/someone/Browser", arguments: flag).authentication)
        XCTAssertNil(PrivateLock.testingConfiguration(profileDirectory: "/tmp/private-lock-test", arguments: ["Yab"]).enabled)
        #if DEBUG
        XCTAssertNotNil(PrivateLock.testingConfiguration(profileDirectory: "/tmp/private-lock-test", arguments: flag).authentication)
        XCTAssertEqual(PrivateLock.testingConfiguration(profileDirectory: "/tmp/private-lock-test", arguments: ["Yab", "-YabPrivateLockTestAuthentication", "off"]).enabled, false)
        #endif
    }
}
